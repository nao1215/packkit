//// Brotli codec — pure-Gleam decoder.
////
//// Decodes RFC 7932 brotli streams, including:
////
//// * The canonical empty stream `0x3F`.
//// * Any stream that uses uncompressed metablocks
////   (`ISUNCOMPRESSED` bit set).
//// * Compressed metablocks with both simple-form (RFC 7932 §3.4)
////   and complex-form (§3.5) prefix-code descriptors.
//// * The command loop (§4): insert-and-copy alphabet → literals
////   from the literal prefix code → distance code → LZ77 copy from
////   the sliding window, with the 4-entry recent-distance ring
////   buffer.
//// * Static-dictionary references (§8): any command whose
////   resolved distance exceeds the current output position falls
////   back to the embedded 122 KiB dictionary, with the prefix /
////   suffix / `OMIT_FIRST` / `OMIT_LAST` / `UPPERCASE_FIRST` /
////   `UPPERCASE_ALL` transforms applied per `transform_idx`.
//// * Context-mapped literal and distance trees (§7.3) when
////   `NTREES > 1`, including the `RLEMAX` zero-run encoding and the
////   optional inverse move-to-front transform.
//// * Block switching (§6) when `NBLTYPES > 1`: each category
////   tracks its own block-type prefix code, a 26-symbol block-length
////   code, and a 2-entry recent-type ring buffer that feeds back
////   into context-map indexing so the right tree is picked for every
////   symbol.
////
//// Encode side:
////
//// * The encoder emits only uncompressed metablocks (one per chunk of
////   up to 65 536 bytes), wrapped in the canonical `WBITS=16` prefix.
////   That produces a valid RFC 7932 stream that any conforming
////   brotli decoder accepts; it does no actual compression but lets
////   `packkit.compress(..., with: codec.brotli())` round-trip
////   end-to-end with `packkit.decompress`.
////
//// The `SHIFT_FIRST` / `SHIFT_ALL` transforms used by the
//// shared-dictionary extension (RFC 8478) are deliberately omitted
//// because the basic RFC 7932 transform set never selects them and
//// this decoder does not accept a custom shared dictionary in the
//// first place.  Implementing them in isolation would create dead
//// code; they will be added together with full shared-dictionary
//// support if and when that feature lands.

import gleam/bit_array
import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import packkit/codec as codecs
import packkit/error
import packkit/internal/brotli_context as brotli_ctx
import packkit/internal/brotli_dictionary as brotli_dict
import packkit/internal/brotli_transform as brotli_xfm
import packkit/limit

/// Brotli codec smart constructor.
pub fn codec() -> codecs.Codec {
  codecs.brotli()
}

/// Encode `bytes` as a Brotli stream made up of uncompressed
/// metablocks (RFC 7932 §9.2 `ISUNCOMPRESSED` form) followed by a
/// final empty `ISLAST` marker.  The output is a valid Brotli stream
/// that any conforming decoder accepts; it does no actual LZ77 or
/// Huffman compression yet, but it does let
/// `packkit.compress(..., with: codec.brotli())` round-trip with the
/// matching decoder.
///
/// Note: RFC 7932 §9.2 mandates that `ISLAST=1` metablocks are
/// compressed (there is no `ISUNCOMPRESSED` bit in that branch), so
/// uncompressed payload bytes are emitted as one or more `ISLAST=0`
/// metablocks and the stream is terminated with a separate empty
/// `ISLAST=1, ISLASTEMPTY=1` marker.
pub fn encode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  let total = bit_array.byte_size(bytes)
  case total {
    // Empty payload still needs a valid stream: WBITS + ISLAST=1
    // ISLASTEMPTY=1 marker.
    0 -> {
      let writer = new_bit_writer()
      let writer = bw_write(writer, 0, 1)
      let writer = emit_empty_last_metablock(writer)
      Ok(bw_flush(writer))
    }
    _ -> Ok(pick_smaller_brotli_stream(bytes, total))
  }
}

// Encode `bytes` two ways and return the smaller stream:
//   1. The existing uncompressed-metablock chain (one or more
//      ISLAST=0 uncompressed metablocks + a final ISLAST=1
//      ISLASTEMPTY=1 marker).
//   2. A single ISLAST=1 compressed metablock that emits the entire
//      payload as literals coded with a complex-form Huffman code
//      (no LZ77 yet — a single insert-and-copy command emits MLEN
//      literals, the copy step is suppressed because the metablock
//      ends as soon as the insert step reaches MLEN per RFC 7932
//      §4 / our own `run_commands` decoder loop).
fn pick_smaller_brotli_stream(bytes: BitArray, total: Int) -> BitArray {
  let uncompressed = build_uncompressed_stream(bytes, total)
  let literals_candidate = build_compressed_literals_stream(bytes, total)
  let lz77_candidate = build_lz77_compressed_stream(bytes, total)
  let candidates = [uncompressed, ..option_to_list(literals_candidate)]
  let candidates = list.append(candidates, option_to_list(lz77_candidate))
  pick_smallest_bit_array(candidates)
}

fn option_to_list(value: Option(BitArray)) -> List(BitArray) {
  case value {
    Some(v) -> [v]
    None -> []
  }
}

fn pick_smallest_bit_array(candidates: List(BitArray)) -> BitArray {
  case candidates {
    [head, ..rest] -> pick_smallest_loop(rest, head)
    [] -> <<>>
  }
}

fn pick_smallest_loop(candidates: List(BitArray), best: BitArray) -> BitArray {
  case candidates {
    [] -> best
    [head, ..rest] ->
      case bit_array.byte_size(head) < bit_array.byte_size(best) {
        True -> pick_smallest_loop(rest, head)
        False -> pick_smallest_loop(rest, best)
      }
  }
}

fn build_uncompressed_stream(bytes: BitArray, total: Int) -> BitArray {
  let writer = new_bit_writer()
  let writer = bw_write(writer, 0, 1)
  let writer = encode_chunks(writer, bytes, 0, total)
  let writer = emit_empty_last_metablock(writer)
  bw_flush(writer)
}

/// Build a single ISLAST=1 compressed metablock whose insert-and-
/// copy stream is exactly one command: insert MLEN literals, copy
/// (suppressed once MLEN is reached).  Returns `None` when the
/// payload won't fit the 16-bit MLEN-1 field (> 65 536 bytes) or
/// when the naive Huffman tree for the literals exceeds the 15-bit
/// code-length cap — the caller falls back to the uncompressed
/// path either way.
fn build_compressed_literals_stream(
  bytes: BitArray,
  total: Int,
) -> Option(BitArray) {
  use <- bool.guard(when: total > 65_536 || total < 1, return: None)
  case build_literal_huffman_lengths(bytes) {
    Error(_) -> None
    Ok(lengths) -> try_emit_compressed_literals(bytes, total, lengths)
  }
}

fn try_emit_compressed_literals(
  bytes: BitArray,
  total: Int,
  lengths: List(Int),
) -> Option(BitArray) {
  // The decoder accepts code lengths up to 15 bits and requires the
  // Huffman space to be exhausted exactly (Kraft equality).  Bail to
  // the uncompressed fallback if either invariant is violated.
  let max_len_ok = max_in_int_list(lengths, 0) <= 15
  let kraft_ok = kraft_slot_total(lengths, 32_768, 15) == 32_768
  case max_len_ok && kraft_ok {
    False -> None
    True -> {
      let codes = assign_brotli_canonical_codes(lengths)
      let writer = new_bit_writer()
      let writer = bw_write(writer, 0, 1)
      let writer =
        emit_compressed_literals_metablock(writer, bytes, total, lengths, codes)
      Some(bw_flush(writer))
    }
  }
}

// Sum the Kraft slot contribution `2^(scale - len)` of every non-zero
// length in the list.  For a valid Huffman code at `max_len = 15`
// this returns exactly `2^15 = 32_768`.
fn kraft_slot_total(lengths: List(Int), _scale: Int, _max_len: Int) -> Int {
  kraft_slot_loop(lengths, 0)
}

fn kraft_slot_loop(lengths: List(Int), acc: Int) -> Int {
  case lengths {
    [] -> acc
    [0, ..rest] -> kraft_slot_loop(rest, acc)
    [len, ..rest] ->
      kraft_slot_loop(rest, acc + int.bitwise_shift_right(32_768, len))
  }
}

fn max_in_int_list(values: List(Int), acc: Int) -> Int {
  case values {
    [] -> acc
    [v, ..rest] ->
      case v > acc {
        True -> max_in_int_list(rest, v)
        False -> max_in_int_list(rest, acc)
      }
  }
}

fn emit_compressed_literals_metablock(
  writer: BitWriter,
  bytes: BitArray,
  mlen: Int,
  literal_lengths: List(Int),
  literal_codes: dict.Dict(Int, #(Int, Int)),
) -> BitWriter {
  // ISLAST=1, ISLASTEMPTY=0.
  let writer = bw_write(writer, 1, 1)
  let writer = bw_write(writer, 0, 1)
  // MNIBBLES: 2-bit field, value N-4.  We always use 4 nibbles so
  // MLEN-1 fits in 16 bits.  Value = 0.
  let writer = bw_write(writer, 0, 2)
  let writer = bw_write(writer, mlen - 1, 16)
  // (No ISUNCOMPRESSED bit because ISLAST=1.)

  // NBLTYPESL: encoded as a prefix code, but for 1 type a single
  // 0 bit suffices.  RFC 7932 §9.2 uses the "NBLTYPES code":
  //   0          -> 1 type (no extra bits)
  //   10        -> 2 types
  //   110xx    -> 3..4 types
  //   ...
  // For our single-type case, emit just a 0 bit.
  let writer = bw_write(writer, 0, 1)
  let writer = bw_write(writer, 0, 1)
  let writer = bw_write(writer, 0, 1)

  // NPOSTFIX (2 bits) + NDIRECT (4 bits).
  let writer = bw_write(writer, 0, 2)
  let writer = bw_write(writer, 0, 4)

  // Context mode for the first (and only) literal block type:
  //   00 = LSB6.  Encoded as a literal 2-bit value.
  let writer = bw_write(writer, 0, 2)

  // NTREESL: prefix-coded; 0 = 1 tree (no context map).
  let writer = bw_write(writer, 0, 1)
  // NTREESD: same.
  let writer = bw_write(writer, 0, 1)

  // HTREEL: complex-form Huffman descriptor for the 256-symbol
  // literal alphabet.
  let writer = emit_complex_huffman_descriptor(writer, literal_lengths, 256)

  // HTREEI: simple-form, 1 symbol from the 704-symbol IC alphabet.
  // We pick the symbol that encodes (insert_code, copy_code=0) for
  // the chosen insert_code.
  let #(insert_code, ic_symbol) = pick_insert_code_and_symbol(mlen)
  let writer = emit_simple_huffman_descriptor(writer, ic_symbol, 704)

  // HTREED: simple-form, 1 symbol from the distance alphabet.
  // alphabet size = 16 + NDIRECT + (48 << NPOSTFIX) = 16 + 0 + 48 = 64.
  // We never use distances so the symbol value is arbitrary — pick 0.
  let writer = emit_simple_huffman_descriptor(writer, 0, 64)

  // Emit the single IC command symbol via the literal-only HTREEI
  // (which is a 1-symbol code, so 0 bits).  Then write the insert
  // extras.
  let writer = bw_write(writer, 0, 0)
  let extras_bits = insert_extra_bits_for(insert_code)
  let extras_value = mlen - insert_base_offset(insert_code)
  let writer = bw_write(writer, extras_value, extras_bits)

  // Emit MLEN literal codes via the HTREEL.  Each literal byte is
  // encoded MSB-first per RFC 7932 §3.3.
  emit_literals_via_huffman(writer, bytes, 0, mlen, literal_codes)
}

fn emit_literals_via_huffman(
  writer: BitWriter,
  bytes: BitArray,
  pos: Int,
  total: Int,
  codes: dict.Dict(Int, #(Int, Int)),
) -> BitWriter {
  case pos >= total {
    True -> writer
    False -> {
      let byte = case bit_array.slice(bytes, pos, 1) {
        Ok(<<b>>) -> b
        _ -> 0
      }
      let #(code, length) = case dict.get(codes, byte) {
        Ok(v) -> v
        Error(_) -> #(0, 0)
      }
      let writer = bw_write_code_msb_first(writer, code, length)
      emit_literals_via_huffman(writer, bytes, pos + 1, total, codes)
    }
  }
}

// Write `code` MSB-first using the LSB-first underlying bit writer.
// The decoder accumulates bits via `accumulated = (accumulated << 1)
// + bit`, so the first bit it consumes ends up as the MSB of the
// final code value — we have to reverse the bit order before
// handing the value to `bw_write`.
fn bw_write_code_msb_first(
  writer: BitWriter,
  code: Int,
  length: Int,
) -> BitWriter {
  case length {
    0 -> writer
    _ -> bw_write(writer, reverse_bits(code, length), length)
  }
}

fn reverse_bits(value: Int, length: Int) -> Int {
  reverse_bits_loop(value, length, 0)
}

fn reverse_bits_loop(value: Int, remaining: Int, acc: Int) -> Int {
  case remaining {
    0 -> acc
    _ ->
      reverse_bits_loop(
        int.bitwise_shift_right(value, 1),
        remaining - 1,
        int.bitwise_or(
          int.bitwise_shift_left(acc, 1),
          int.bitwise_and(value, 1),
        ),
      )
  }
}

// --- Insert-and-copy command symbol selection -------------------------
//
// We emit a single IC command per metablock that says "insert MLEN
// bytes, then copy K bytes" where K is implied by the IC symbol's
// copy_code.  The copy step is skipped because the metablock ends
// once `remaining <= 0` after the insert step (RFC 7932 §4; our
// `run_commands` decoder explicitly bails before the copy step in
// that case).
//
// To avoid the cells whose distance code triggers a Huffman read we
// stick to insert_code 0..7 (cell_idx 0) for tiny payloads and use
// cells 4 / 7 only for the larger insert_codes, where the suppressed
// copy step keeps the distance Huffman code unread anyway.

fn pick_insert_code_and_symbol(mlen: Int) -> #(Int, Int) {
  let code = pick_insert_code_for_length(mlen)
  let symbol = ic_symbol_for(code)
  #(code, symbol)
}

fn pick_insert_code_for_length(mlen: Int) -> Int {
  case mlen {
    n if n <= 5 -> n
    n if n <= 7 -> 6
    n if n <= 9 -> 7
    n if n <= 13 -> 8
    n if n <= 17 -> 9
    n if n <= 25 -> 10
    n if n <= 33 -> 11
    n if n <= 49 -> 12
    n if n <= 65 -> 13
    n if n <= 97 -> 14
    n if n <= 129 -> 15
    n if n <= 193 -> 16
    n if n <= 321 -> 17
    n if n <= 577 -> 18
    n if n <= 1089 -> 19
    n if n <= 2113 -> 20
    n if n <= 6209 -> 21
    n if n <= 22_593 -> 22
    _ -> 23
  }
}

fn insert_base_offset(code: Int) -> Int {
  case code {
    n if n <= 5 -> n
    6 -> 6
    7 -> 8
    8 -> 10
    9 -> 14
    10 -> 18
    11 -> 26
    12 -> 34
    13 -> 50
    14 -> 66
    15 -> 98
    16 -> 130
    17 -> 194
    18 -> 322
    19 -> 578
    20 -> 1090
    21 -> 2114
    22 -> 6210
    _ -> 22_594
  }
}

fn insert_extra_bits_for(code: Int) -> Int {
  case code {
    n if n <= 5 -> 0
    6 | 7 -> 1
    8 | 9 -> 2
    10 | 11 -> 3
    12 | 13 -> 4
    14 | 15 -> 5
    16 -> 6
    17 -> 7
    18 -> 8
    19 -> 9
    20 -> 10
    21 -> 12
    22 -> 14
    _ -> 24
  }
}

// IC symbol with copy_code = 0.  Mirrors the cell-layout mapping in
// the decoder's `cmd_lut_entry`:
//
//   insert_code 0..7  -> cell_idx 0 (cell_pos 0), symbol = insert_code * 8.
//   insert_code 8..15 -> cell_idx 4 (cell_pos 8), symbol = 256 + (ic-8) * 8.
//   insert_code 16..23-> cell_idx 7 (cell_pos 16), symbol = 448 + (ic-16) * 8.
fn ic_symbol_for(insert_code: Int) -> Int {
  case insert_code {
    n if n <= 7 -> n * 8
    n if n <= 15 -> 256 + { n - 8 } * 8
    n -> 448 + { n - 16 } * 8
  }
}

// --- Simple-form Huffman descriptor ----------------------------------
//
// 2-bit descriptor `01` (value 1 = "simple form"), 2-bit NSYM-1
// (we always use 1 symbol → 0), then one alphabet-bit value.

fn emit_simple_huffman_descriptor(
  writer: BitWriter,
  symbol: Int,
  alphabet_size: Int,
) -> BitWriter {
  // Descriptor value 1 = simple form.  bw_write puts low bits first,
  // so writing value 1 with count 2 emits bits 1, 0 — decoder
  // reads them low-first and sees `1`.  ✓
  let writer = bw_write(writer, 1, 2)
  // NSYM - 1 = 0 (one symbol).
  let writer = bw_write(writer, 0, 2)
  let alphabet_bits = ceil_log2(alphabet_size)
  bw_write(writer, symbol, alphabet_bits)
}

// --- Complex-form Huffman descriptor (RFC 7932 §3.5) -----------------
//
// Two-stage:
//   1. Write the 18 "code-length code" lengths (CLCL), each via a
//      fixed 4-bit lookup.  HSKIP leading entries are implicitly 0
//      and not transmitted; HSKIP is the descriptor value 0/2/3.
//   2. Build a canonical CL Huffman code from those lengths.  Use
//      it to encode the actual alphabet's code lengths, RLE-encoded
//      via symbols 16 (repeat-prev 3..6 + 2 extra bits) and 17
//      (repeat-zero 3..10 + 3 extra bits).

fn emit_complex_huffman_descriptor(
  writer: BitWriter,
  lengths: List(Int),
  _alphabet_size: Int,
) -> BitWriter {
  // Compose the RLE sequence of CL symbols (each in 0..17) plus
  // any extra-bit pairs (for symbols 16 / 17).  Also tally how
  // often each CL symbol appears so we can build the CL Huffman
  // code.
  let rle = rle_encode_lengths(lengths)
  let cl_freqs = tally_cl_symbols(rle, dict.new())
  // Build CL Huffman code lengths from frequencies (length-limited
  // to 5 bits — that's all the fixed CL-code-length lookup can
  // encode).
  let cl_lengths_dict = build_cl_huffman_lengths(cl_freqs)
  let cl_lengths_list = cl_length_list(cl_lengths_dict)

  // Pick HSKIP: choose the leading prefix of `cl_code_order` whose
  // length entries we can omit (i.e. they're zero).  HSKIP must be
  // 0, 2, or 3 per RFC 7932 §3.5 (the 2-bit descriptor).
  let hskip = pick_hskip(cl_lengths_dict)

  // Emit the 2-bit descriptor (HSKIP itself).
  let writer = bw_write(writer, hskip, 2)

  // Emit the CL-CL values in `cl_code_order[hskip..]` order.
  let to_emit = list.drop(cl_code_order(), hskip)
  let writer = emit_cl_lengths(writer, to_emit, cl_lengths_dict)

  // Build canonical CL Huffman code from the lengths.
  let cl_codes = assign_brotli_canonical_codes(cl_lengths_list)

  // Encode the alphabet's lengths using the CL code + RLE codes.
  emit_rle_via_cl(writer, rle, cl_codes)
}

// CL code order used by RFC 7932 §3.5; matches the decoder's
// `cl_code_order()`.
fn cl_code_order_writer() -> List(Int) {
  [1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15]
}

// Inverse of `cl_prefix_lookup`: given a code-length-code-length in
// 0..5, returns `(bits_to_emit, value)` for `bw_write`.
fn cl_clcl_emit(clcl_value: Int) -> #(Int, Int) {
  case clcl_value {
    0 -> #(2, 0)
    1 -> #(4, 7)
    2 -> #(3, 3)
    3 -> #(2, 2)
    4 -> #(2, 1)
    _ -> #(4, 15)
  }
}

// Emit code-length-code lengths in `cl_code_order[hskip..]` order, but
// stop as soon as the CL Huffman space is exhausted (`space <= 0`).
// `read_cl_code_lengths` in the decoder exits early when `new_space <=
// 0`; any further zero-length entries we emit would leak as spurious
// Lit(0) atoms into the symbol-code-length section and shift the
// alphabet (RFC 7932 §3.5; see `read_one_cl`).
fn emit_cl_lengths(
  writer: BitWriter,
  order: List(Int),
  cl_lengths: dict.Dict(Int, Int),
) -> BitWriter {
  emit_cl_lengths_loop(writer, order, cl_lengths, 32)
}

fn emit_cl_lengths_loop(
  writer: BitWriter,
  order: List(Int),
  cl_lengths: dict.Dict(Int, Int),
  space: Int,
) -> BitWriter {
  case order {
    [] -> writer
    [sym, ..rest] -> {
      let len = case dict.get(cl_lengths, sym) {
        Ok(v) -> v
        Error(_) -> 0
      }
      let #(bits, value) = cl_clcl_emit(len)
      let writer = bw_write(writer, value, bits)
      let new_space = case len {
        0 -> space
        _ -> space - int.bitwise_shift_right(32, len)
      }
      case new_space <= 0 {
        True -> writer
        False -> emit_cl_lengths_loop(writer, rest, cl_lengths, new_space)
      }
    }
  }
}

fn pick_hskip(cl_lengths: dict.Dict(Int, Int)) -> Int {
  // HSKIP must be 0, 2, or 3.  Pick 3 when the first 3 codes in
  // `cl_code_order` are unused; otherwise 2 when the first 2 are
  // unused; otherwise 0.
  let order = cl_code_order_writer()
  case order {
    [a, b, c, ..] ->
      case all_zero_in(cl_lengths, [a, b, c]), all_zero_in(cl_lengths, [a, b]) {
        True, _ -> 3
        _, True -> 2
        _, _ -> 0
      }
    _ -> 0
  }
}

fn all_zero_in(cl_lengths: dict.Dict(Int, Int), syms: List(Int)) -> Bool {
  case syms {
    [] -> True
    [s, ..rest] ->
      case dict.get(cl_lengths, s) {
        Ok(0) -> all_zero_in(cl_lengths, rest)
        Error(_) -> all_zero_in(cl_lengths, rest)
        Ok(_) -> False
      }
  }
}

// Run-length encode the alphabet's code lengths.  Produces a list
// of `RleAtom` values; consecutive 0-length runs collapse onto
// symbol 17 with a 3-bit extra (3..10 entries per symbol); other
// repeats collapse onto symbol 16 with a 2-bit extra (3..6 entries
// per symbol).  Single non-zero entries emit symbol = length.
type RleAtom {
  RleLit(value: Int)
  RleRepPrev(extra: Int)
  // 0..3, decoder sees count = 3 + extra
  RleRepZero(extra: Int)
  // 0..7, decoder sees count = 3 + extra
}

fn rle_encode_lengths(lengths: List(Int)) -> List(RleAtom) {
  // The decoder stops reading code-length codes once the Kraft sum
  // is exhausted (RFC 7932 §3.5; `read_symbol_code_lengths` exits
  // when `state.space <= 0`).  Any RLE atoms emitted for trailing
  // zero entries beyond the last non-zero length would then leak
  // into the next descriptor's bitstream and corrupt the stream,
  // so trim those trailing zeros before encoding.
  let trimmed = trim_trailing_zeros(lengths)
  let runs = collect_runs(trimmed, [])
  expand_runs(runs, [])
}

fn trim_trailing_zeros(lengths: List(Int)) -> List(Int) {
  trim_trailing_zeros_loop(list.reverse(lengths), [])
}

fn trim_trailing_zeros_loop(
  rev_lengths: List(Int),
  acc: List(Int),
) -> List(Int) {
  case rev_lengths, acc {
    [], _ -> acc
    [0, ..rest], [] -> trim_trailing_zeros_loop(rest, [])
    [head, ..rest], _ -> trim_trailing_zeros_loop(rest, [head, ..acc])
  }
}

fn collect_runs(
  remaining: List(Int),
  acc: List(#(Int, Int)),
) -> List(#(Int, Int)) {
  case remaining {
    [] -> list.reverse(acc)
    [v, ..rest] ->
      case acc {
        [#(top_value, top_count), ..tail] if top_value == v ->
          collect_runs(rest, [#(top_value, top_count + 1), ..tail])
        _ -> collect_runs(rest, [#(v, 1), ..acc])
      }
  }
}

fn expand_runs(runs: List(#(Int, Int)), acc: List(RleAtom)) -> List(RleAtom) {
  case runs {
    [] -> list.reverse(acc)
    [#(value, count), ..rest] -> {
      let additions = case value {
        0 -> expand_zero_run(count, [])
        v -> expand_non_zero_run(v, count, [])
      }
      expand_runs(rest, list.append(list.reverse(additions), acc))
    }
  }
}

// Expand a zero run.  Symbol 17 covers 3..10 entries per occurrence;
// to avoid the run-length chaining the decoder applies to
// consecutive code-17 emissions (RFC 7932 §3.5), we follow each
// RepZero with a single Lit(0) that adds one extra zero and resets
// `state.repeat_len` so the next RepZero starts fresh.
fn expand_zero_run(count: Int, acc: List(RleAtom)) -> List(RleAtom) {
  case count {
    0 -> list.reverse(acc)
    n if n < 3 -> expand_zero_run(n - 1, [RleLit(0), ..acc])
    n if n <= 10 -> expand_zero_run(0, [RleRepZero(extra: n - 3), ..acc])
    _ ->
      // Take the largest unchained step (10 zeros via RepZero +
      // 1 zero via Lit = 11 zeros per cycle).  Lit(0) doubles as
      // the reset because `apply_single_code_length` sets
      // `state.repeat = 0, state.repeat_len = 0` for any code < 16,
      // including code 0.
      expand_zero_run(count - 11, [RleLit(0), RleRepZero(extra: 7), ..acc])
  }
}

// Expand a non-zero run.  First emit a Lit(value) so the decoder's
// "previous non-zero code length" is set to value, then fill the
// remaining `count - 1` entries with RepPrev codes (3..6 entries
// per code) with Lit(value) separators that block the consecutive-
// code-16 chaining.
fn expand_non_zero_run(
  value: Int,
  count: Int,
  acc: List(RleAtom),
) -> List(RleAtom) {
  case count {
    0 -> list.reverse(acc)
    n if n <= 3 ->
      // Short runs: just emit `n` lits.  RepPrev's 2 extra bits
      // would only break even at run length 3.
      append_lits_reverse(n, value, acc)
    n -> {
      let acc = [RleLit(value), ..acc]
      expand_rep_prev(value, n - 1, acc)
    }
  }
}

fn expand_rep_prev(
  value: Int,
  remaining: Int,
  acc: List(RleAtom),
) -> List(RleAtom) {
  case remaining {
    0 -> list.reverse(acc)
    n if n < 3 -> append_lits_reverse(n, value, acc)
    n if n <= 6 ->
      append_lits_reverse(0, value, [RleRepPrev(extra: n - 3), ..acc])
    _ ->
      // RepPrev(6 entries) + Lit(value) (1 entry) = 7 entries
      // per cycle.  Lit(value) acts as the chain reset.
      expand_rep_prev(value, remaining - 7, [
        RleLit(value),
        RleRepPrev(extra: 3),
        ..acc
      ])
  }
}

fn append_lits_reverse(
  count: Int,
  value: Int,
  acc: List(RleAtom),
) -> List(RleAtom) {
  case count {
    0 -> list.reverse(acc)
    _ -> append_lits_reverse(count - 1, value, [RleLit(value), ..acc])
  }
}

fn tally_cl_symbols(
  rle: List(RleAtom),
  acc: dict.Dict(Int, Int),
) -> dict.Dict(Int, Int) {
  case rle {
    [] -> acc
    [atom, ..rest] -> {
      let sym = case atom {
        RleLit(v) -> v
        RleRepPrev(_) -> 16
        RleRepZero(_) -> 17
      }
      let cur = case dict.get(acc, sym) {
        Ok(v) -> v
        Error(_) -> 0
      }
      tally_cl_symbols(rest, dict.insert(acc, sym, cur + 1))
    }
  }
}

// Build a CL Huffman code-length table (symbols 0..17, max length 5).
// `cl_clcl_emit` only encodes lengths 0..5 — anything deeper would
// silently fall through to the wildcard branch (`length 5`) and
// produce a descriptor the decoder rejects with "code-length codes
// oversubscribe Huffman space".  We therefore length-limit to 5 by
// constructing the depth distribution that exhausts the 32-slot
// Huffman space exactly (Kraft equality), then assign the shortest
// available lengths to the most-frequent symbols.
fn build_cl_huffman_lengths(freqs: dict.Dict(Int, Int)) -> dict.Dict(Int, Int) {
  let pairs =
    dict.fold(freqs, [], fn(acc, sym, count) {
      case count > 0 {
        True -> [#(count, sym), ..acc]
        False -> acc
      }
    })
  // Sort by frequency descending so the most-frequent CL symbol
  // pops out first and gets the shortest length.
  let sorted = list.sort(pairs, fn(a, b) { int.compare(b.0, a.0) })
  case sorted {
    [] -> dict.new()
    [#(_, single)] ->
      // Decoder accepts a single-symbol CL code via the
      // `num_codes == 1` branch in `validate_cl_space`, where the
      // length is allowed to be < 1.  Use length 1 — the
      // `cl_clcl_emit` table encodes that as `0111` (4 bits).
      dict.from_list([#(single, 1)])
    _ -> {
      let leaf_count = list.length(sorted)
      let lengths = limited_huffman_lengths(leaf_count, 5)
      assign_lengths_to_symbols(sorted, lengths, dict.new())
    }
  }
}

// Compute a length-limited Huffman depth distribution for `n` leaves
// with `max_len` maximum depth, satisfying the Kraft equality.
// Returns the list of lengths in ascending order (shortest first)
// — caller pairs them with frequency-sorted symbols so the most-
// frequent get the shortest codes.
fn limited_huffman_lengths(n: Int, max_len: Int) -> List(Int) {
  // Counts at each depth; start with `2^max_len` leaves all at the
  // bottom (a fully-balanced binary tree).  Iteratively merge two
  // leaves at the deepest occupied level into one leaf one level up
  // until total leaves equal `n`.  Net effect on the Kraft sum is
  // zero (1/2 at level L = 1/4 + 1/4 at level L+1), so the result
  // always satisfies Kraft equality.
  let initial = int.bitwise_shift_left(1, max_len)
  let counts = list_replicate(max_len + 1, 0)
  let counts = list_replace_at(counts, max_len, initial)
  let counts = collapse_to_n(counts, initial, n, max_len)
  expand_counts_to_lengths(counts, 0, [])
}

fn list_replicate(count: Int, value: Int) -> List(Int) {
  list_replicate_loop(count, value, [])
}

fn list_replicate_loop(count: Int, value: Int, acc: List(Int)) -> List(Int) {
  case count {
    0 -> acc
    _ -> list_replicate_loop(count - 1, value, [value, ..acc])
  }
}

fn list_replace_at(lst: List(Int), idx: Int, value: Int) -> List(Int) {
  list_replace_at_loop(lst, idx, value, 0, [])
}

fn list_replace_at_loop(
  lst: List(Int),
  idx: Int,
  value: Int,
  cur: Int,
  acc: List(Int),
) -> List(Int) {
  case lst {
    [] -> list.reverse(acc)
    [head, ..rest] -> {
      let new_head = case cur == idx {
        True -> value
        False -> head
      }
      list_replace_at_loop(rest, idx, value, cur + 1, [new_head, ..acc])
    }
  }
}

fn collapse_to_n(
  counts: List(Int),
  total_leaves: Int,
  target: Int,
  max_len: Int,
) -> List(Int) {
  case total_leaves <= target {
    True -> counts
    False -> {
      let depth = deepest_with_pair(counts, max_len)
      case depth < 1 {
        True -> counts
        False -> {
          let counts =
            list_replace_at(counts, depth, list_at_int(counts, depth) - 2)
          let counts =
            list_replace_at(
              counts,
              depth - 1,
              list_at_int(counts, depth - 1) + 1,
            )
          collapse_to_n(counts, total_leaves - 1, target, max_len)
        }
      }
    }
  }
}

fn list_at_int(lst: List(Int), idx: Int) -> Int {
  case lst {
    [] -> 0
    [head, ..rest] ->
      case idx {
        0 -> head
        _ -> list_at_int(rest, idx - 1)
      }
  }
}

fn deepest_with_pair(counts: List(Int), max_idx: Int) -> Int {
  deepest_with_pair_loop(counts, max_idx, 0, -1)
}

fn deepest_with_pair_loop(
  counts: List(Int),
  max_idx: Int,
  cur: Int,
  best: Int,
) -> Int {
  case counts {
    [] -> best
    [head, ..rest] -> {
      let new_best = case cur <= max_idx && head >= 2 && cur > best {
        True -> cur
        False -> best
      }
      deepest_with_pair_loop(rest, max_idx, cur + 1, new_best)
    }
  }
}

fn expand_counts_to_lengths(
  counts: List(Int),
  depth: Int,
  acc: List(Int),
) -> List(Int) {
  case counts {
    [] -> list.reverse(acc)
    [head, ..rest] -> {
      let acc = append_n(depth, head, acc)
      expand_counts_to_lengths(rest, depth + 1, acc)
    }
  }
}

fn append_n(value: Int, count: Int, acc: List(Int)) -> List(Int) {
  case count {
    0 -> acc
    _ -> append_n(value, count - 1, [value, ..acc])
  }
}

fn assign_lengths_to_symbols(
  freq_pairs: List(#(Int, Int)),
  lengths: List(Int),
  acc: dict.Dict(Int, Int),
) -> dict.Dict(Int, Int) {
  case freq_pairs, lengths {
    [], _ -> acc
    _, [] -> acc
    [#(_, sym), ..rest_pairs], [len, ..rest_lens] ->
      assign_lengths_to_symbols(
        rest_pairs,
        rest_lens,
        dict.insert(acc, sym, len),
      )
  }
}

type BrNode {
  BrLeaf(symbol: Int)
  BrInternal(left: BrNode, right: BrNode)
}

fn br_merge(nodes: List(#(Int, BrNode))) -> BrNode {
  case nodes {
    [#(_, single)] -> single
    [a, b, ..rest] -> {
      let combined = #(a.0 + b.0, BrInternal(a.1, b.1))
      br_merge(insert_brnode_sorted(combined, rest))
    }
    _ -> BrLeaf(0)
  }
}

fn insert_brnode_sorted(
  item: #(Int, BrNode),
  nodes: List(#(Int, BrNode)),
) -> List(#(Int, BrNode)) {
  case nodes {
    [] -> [item]
    [head, ..rest] ->
      case item.0 <= head.0 {
        True -> [item, head, ..rest]
        False -> [head, ..insert_brnode_sorted(item, rest)]
      }
  }
}

fn br_extract_lengths(
  node: BrNode,
  depth: Int,
  acc: dict.Dict(Int, Int),
) -> dict.Dict(Int, Int) {
  case node {
    BrLeaf(sym) -> {
      let length = case depth {
        0 -> 1
        _ -> depth
      }
      dict.insert(acc, sym, length)
    }
    BrInternal(l, r) -> {
      let acc = br_extract_lengths(l, depth + 1, acc)
      br_extract_lengths(r, depth + 1, acc)
    }
  }
}

fn cl_length_list(d: dict.Dict(Int, Int)) -> List(Int) {
  // 18-entry list, indices 0..17.
  cl_length_list_loop(d, 0, [])
}

fn cl_length_list_loop(
  d: dict.Dict(Int, Int),
  idx: Int,
  acc: List(Int),
) -> List(Int) {
  case idx >= 18 {
    True -> list.reverse(acc)
    False -> {
      let len = case dict.get(d, idx) {
        Ok(v) -> v
        Error(_) -> 0
      }
      cl_length_list_loop(d, idx + 1, [len, ..acc])
    }
  }
}

fn emit_rle_via_cl(
  writer: BitWriter,
  rle: List(RleAtom),
  codes: dict.Dict(Int, #(Int, Int)),
) -> BitWriter {
  case rle {
    [] -> writer
    [atom, ..rest] -> {
      let writer = case atom {
        RleLit(v) -> emit_cl_code(writer, codes, v)
        RleRepPrev(extra) -> {
          let writer = emit_cl_code(writer, codes, 16)
          bw_write(writer, extra, 2)
        }
        RleRepZero(extra) -> {
          let writer = emit_cl_code(writer, codes, 17)
          bw_write(writer, extra, 3)
        }
      }
      emit_rle_via_cl(writer, rest, codes)
    }
  }
}

fn emit_cl_code(
  writer: BitWriter,
  codes: dict.Dict(Int, #(Int, Int)),
  symbol: Int,
) -> BitWriter {
  let #(code, length) = case dict.get(codes, symbol) {
    Ok(v) -> v
    Error(_) -> #(0, 0)
  }
  bw_write_code_msb_first(writer, code, length)
}

// --- Literal Huffman code construction --------------------------------
//
// Computes code lengths for the 256-symbol literal alphabet via the
// standard frequency-merge Huffman.  Returns `Error(Nil)` when the
// payload has fewer than two distinct bytes (we handle that case
// by falling back to the uncompressed path).

fn build_literal_huffman_lengths(bytes: BitArray) -> Result(List(Int), Nil) {
  let freqs = brotli_byte_freqs(bytes, dict.new())
  let distinct = dict.fold(freqs, 0, fn(acc, _k, _v) { acc + 1 })
  case distinct < 2 {
    True -> Error(Nil)
    False -> {
      let pairs =
        dict.fold(freqs, [], fn(acc, sym, count) {
          case count > 0 {
            True -> [#(count, sym), ..acc]
            False -> acc
          }
        })
      let sorted = list.sort(pairs, fn(a, b) { int.compare(a.0, b.0) })
      let nodes = list.map(sorted, fn(p) { #(p.0, BrLeaf(p.1)) })
      let root = br_merge(nodes)
      let dict_lengths = br_extract_lengths(root, 0, dict.new())
      Ok(build_literal_length_list(dict_lengths, 0, []))
    }
  }
}

fn brotli_byte_freqs(
  bytes: BitArray,
  acc: dict.Dict(Int, Int),
) -> dict.Dict(Int, Int) {
  case bytes {
    <<b, rest:bytes>> -> {
      let cur = case dict.get(acc, b) {
        Ok(v) -> v
        Error(_) -> 0
      }
      brotli_byte_freqs(rest, dict.insert(acc, b, cur + 1))
    }
    _ -> acc
  }
}

fn build_literal_length_list(
  d: dict.Dict(Int, Int),
  idx: Int,
  acc: List(Int),
) -> List(Int) {
  case idx >= 256 {
    True -> list.reverse(acc)
    False -> {
      let len = case dict.get(d, idx) {
        Ok(v) -> v
        Error(_) -> 0
      }
      build_literal_length_list(d, idx + 1, [len, ..acc])
    }
  }
}

// Canonical Huffman code assignment matching the decoder's
// `assign_canonical` (and the single-symbol fast path in
// `canonicalise_from_pairs`): sort by `(length asc, symbol asc)` and
// assign codes via the standard "shift on length change, +1 per step"
// recurrence.  Returns `dict[symbol] = #(code, length)`.
//
// **Single-symbol special case**: when only one symbol has a non-zero
// declared length, the decoder treats it as a length-0 (zero-bit) code
// — `decode_prefix_walk` exits immediately because
// `find_prefix_entry` matches `length == 0 && code == 0`.  The encoder
// must mirror that: emit zero bits for the lone symbol instead of the
// 1-bit code canonical assignment would compute, or the descriptor's
// trailing bits leak into the next section.
fn assign_brotli_canonical_codes(
  lengths: List(Int),
) -> dict.Dict(Int, #(Int, Int)) {
  let pairs =
    list.index_fold(lengths, [], fn(acc, len, sym) {
      case len > 0 {
        True -> [#(sym, len), ..acc]
        False -> acc
      }
    })
  case pairs {
    [#(sym, _)] -> dict.from_list([#(sym, #(0, 0))])
    _ -> {
      let by_sym =
        list.sort(pairs, fn(a, b) {
          let #(sa, _) = a
          let #(sb, _) = b
          int.compare(sa, sb)
        })
      let by_len =
        list.sort(by_sym, fn(a, b) {
          let #(_, la) = a
          let #(_, lb) = b
          int.compare(la, lb)
        })
      assign_canonical_loop(by_len, 0, 0, dict.new())
    }
  }
}

fn assign_canonical_loop(
  pairs: List(#(Int, Int)),
  next_code: Int,
  prev_length: Int,
  acc: dict.Dict(Int, #(Int, Int)),
) -> dict.Dict(Int, #(Int, Int)) {
  case pairs {
    [] -> acc
    [#(sym, len), ..rest] -> {
      let shifted = int.bitwise_shift_left(next_code, len - prev_length)
      assign_canonical_loop(
        rest,
        shifted + 1,
        len,
        dict.insert(acc, sym, #(shifted, len)),
      )
    }
  }
}

/// Maximum payload bytes per uncompressed metablock.  RFC 7932 §9.2
/// permits up to `MNIBBLES=6` (16 MiB), but we stay at the 4-nibble
/// `MLEN-1` form (65 536-byte ceiling) so every emitted metablock
/// shares an identical bit layout.
const uncompressed_chunk_size: Int = 65_536

// --- LZ77 compressed-metablock encoder -------------------------------
//
// Greedy 3-byte hash-chain match finder over the payload (32 KiB
// window).  Each match becomes a brotli insert-and-copy command —
// `insert_len` literals then `copy_len` bytes copied from `distance`
// bytes back.  The encoder picks `cell_idx ≥ 2` IC cells so every
// command's distance is read explicitly from the distance Huffman
// tree rather than reused from the ring buffer.  Three Huffman codes
// (256 literal, 704 IC, 64 distance) are emitted via the same
// complex-form descriptor as the literals-only path.  RFC 7932 §5 /
// §9.2.

const lz77_min_match: Int = 4

const lz77_max_match: Int = 100

const lz77_max_distance: Int = 32_768

type BrCommand {
  BrCommand(insert_len: Int, copy_len: Int, distance: Int)
}

fn build_lz77_compressed_stream(
  bytes: BitArray,
  total: Int,
) -> Option(BitArray) {
  use <- bool.guard(
    when: total > 65_536 || total < lz77_min_match,
    return: None,
  )
  let commands = build_lz77_commands(bytes, total)
  case has_real_match(commands, False) {
    False -> None
    True -> try_emit_lz77_metablock(bytes, total, commands)
  }
}

fn has_real_match(commands: List(BrCommand), found: Bool) -> Bool {
  case commands, found {
    _, True -> True
    [], _ -> False
    [cmd, ..rest], _ ->
      case cmd.copy_len > 0 {
        True -> has_real_match(rest, True)
        False -> has_real_match(rest, False)
      }
  }
}

fn try_emit_lz77_metablock(
  bytes: BitArray,
  total: Int,
  commands: List(BrCommand),
) -> Option(BitArray) {
  // Collect frequencies for each of the three Huffman alphabets.
  let lit_freqs = tally_literal_freqs(bytes, commands, 0, dict.new())
  let ic_freqs = tally_ic_freqs(commands, dict.new())
  let dist_freqs = tally_distance_freqs(commands, dict.new())

  let lit_lengths = build_alphabet_lengths(lit_freqs, 256)
  let ic_lengths = build_alphabet_lengths(ic_freqs, 704)
  let dist_lengths = build_alphabet_lengths(dist_freqs, 64)

  case
    alphabet_valid(lit_lengths)
    && alphabet_valid(ic_lengths)
    && alphabet_valid(dist_lengths)
  {
    False -> None
    True -> {
      let lit_codes = assign_brotli_canonical_codes(lit_lengths)
      let ic_codes = assign_brotli_canonical_codes(ic_lengths)
      let dist_codes = assign_brotli_canonical_codes(dist_lengths)
      let writer = new_bit_writer()
      let writer = bw_write(writer, 0, 1)
      let writer =
        emit_lz77_metablock_body(
          writer,
          bytes,
          total,
          commands,
          lit_lengths,
          lit_codes,
          ic_lengths,
          ic_codes,
          dist_lengths,
          dist_codes,
        )
      Some(bw_flush(writer))
    }
  }
}

fn alphabet_valid(lengths: List(Int)) -> Bool {
  // Reject any alphabet whose lengths blow the 15-bit cap or fail
  // the Kraft-equality check (decoder's
  // `validate_symbol_lengths` / `read_symbol_code_lengths` both
  // require it).
  max_in_int_list(lengths, 0) <= 15
  && kraft_slot_total(lengths, 32_768, 15) == 32_768
}

fn build_alphabet_lengths(
  freqs: dict.Dict(Int, Int),
  alphabet_size: Int,
) -> List(Int) {
  let pairs =
    dict.fold(freqs, [], fn(acc, sym, count) {
      case count > 0 {
        True -> [#(count, sym), ..acc]
        False -> acc
      }
    })
  let distinct = list.length(pairs)
  case distinct {
    0 -> alphabet_lengths_for_single(alphabet_size, 0)
    1 -> {
      // Single symbol — alphabet must still carry a valid Huffman
      // code (the decoder accepts a 0-bit code via the simple-form
      // single-symbol path, but the complex-form descriptor needs at
      // least one length).  Give the one used symbol length 1 and
      // pair it with a second unused symbol also at length 1 so
      // Kraft = 1.
      let used = case pairs {
        [#(_, sym), ..] -> sym
        [] -> 0
      }
      let partner = case used {
        0 -> 1
        _ -> 0
      }
      let lengths = alphabet_lengths_for_single(alphabet_size, 0)
      let lengths = replace_length(lengths, used, 1)
      replace_length(lengths, partner, 1)
    }
    _ -> {
      let sorted = list.sort(pairs, fn(a, b) { int.compare(a.0, b.0) })
      let nodes = list.map(sorted, fn(p) { #(p.0, BrLeaf(p.1)) })
      let root = br_merge(nodes)
      let dict_lengths = br_extract_lengths(root, 0, dict.new())
      build_length_list_for_alphabet(dict_lengths, 0, alphabet_size, [])
    }
  }
}

fn alphabet_lengths_for_single(alphabet_size: Int, value: Int) -> List(Int) {
  alphabet_lengths_for_single_loop(alphabet_size, value, [])
}

fn alphabet_lengths_for_single_loop(
  remaining: Int,
  value: Int,
  acc: List(Int),
) -> List(Int) {
  case remaining {
    0 -> acc
    _ -> alphabet_lengths_for_single_loop(remaining - 1, value, [value, ..acc])
  }
}

fn replace_length(lengths: List(Int), idx: Int, value: Int) -> List(Int) {
  replace_length_loop(lengths, idx, value, 0, [])
}

fn replace_length_loop(
  lengths: List(Int),
  idx: Int,
  value: Int,
  cur: Int,
  acc: List(Int),
) -> List(Int) {
  case lengths {
    [] -> list.reverse(acc)
    [head, ..rest] -> {
      let next = case cur == idx {
        True -> value
        False -> head
      }
      replace_length_loop(rest, idx, value, cur + 1, [next, ..acc])
    }
  }
}

fn build_length_list_for_alphabet(
  d: dict.Dict(Int, Int),
  idx: Int,
  alphabet_size: Int,
  acc: List(Int),
) -> List(Int) {
  case idx >= alphabet_size {
    True -> list.reverse(acc)
    False -> {
      let len = case dict.get(d, idx) {
        Ok(v) -> v
        Error(_) -> 0
      }
      build_length_list_for_alphabet(d, idx + 1, alphabet_size, [len, ..acc])
    }
  }
}

// -- LZ77 match finder ------------------------------------------------

fn build_lz77_commands(bytes: BitArray, total: Int) -> List(BrCommand) {
  let #(commands_rev, _) = lz77_match_loop(bytes, 0, total, 0, dict.new(), [])
  let trailing = total - find_consumed_position(commands_rev, 0)
  let commands_rev = case trailing {
    0 -> commands_rev
    _ -> [
      BrCommand(insert_len: trailing, copy_len: 0, distance: 0),
      ..commands_rev
    ]
  }
  list.reverse(commands_rev)
}

fn find_consumed_position(commands_rev: List(BrCommand), acc: Int) -> Int {
  case commands_rev {
    [] -> acc
    list -> find_consumed_position_sum(list, 0)
  }
}

fn find_consumed_position_sum(commands_rev: List(BrCommand), acc: Int) -> Int {
  case commands_rev {
    [] -> acc
    [cmd, ..rest] ->
      find_consumed_position_sum(rest, acc + cmd.insert_len + cmd.copy_len)
  }
}

fn lz77_match_loop(
  bytes: BitArray,
  pos: Int,
  total: Int,
  last_emit: Int,
  hashes: dict.Dict(Int, Int),
  commands_rev: List(BrCommand),
) -> #(List(BrCommand), Int) {
  case pos + lz77_min_match > total {
    True -> #(commands_rev, last_emit)
    False -> {
      let b0 = brotli_byte_at(bytes, pos)
      let b1 = brotli_byte_at(bytes, pos + 1)
      let b2 = brotli_byte_at(bytes, pos + 2)
      let b3 = brotli_byte_at(bytes, pos + 3)
      let key = brotli_hash4(b0, b1, b2, b3)
      case dict.get(hashes, key) {
        Error(_) ->
          lz77_match_loop(
            bytes,
            pos + 1,
            total,
            last_emit,
            dict.insert(hashes, key, pos),
            commands_rev,
          )
        Ok(prev) ->
          lz77_consider_match(
            bytes,
            pos,
            total,
            last_emit,
            hashes,
            commands_rev,
            prev,
          )
      }
    }
  }
}

fn lz77_consider_match(
  bytes: BitArray,
  pos: Int,
  total: Int,
  last_emit: Int,
  hashes: dict.Dict(Int, Int),
  commands_rev: List(BrCommand),
  prev: Int,
) -> #(List(BrCommand), Int) {
  let distance = pos - prev
  case distance <= 0 || distance > lz77_max_distance {
    True ->
      lz77_match_loop(
        bytes,
        pos + 1,
        total,
        last_emit,
        dict.insert(hashes, brotli_byte_key(bytes, pos), pos),
        commands_rev,
      )
    False -> {
      let cap = case total - pos < lz77_max_match {
        True -> total - pos
        False -> lz77_max_match
      }
      let m_len = brotli_match_len(bytes, prev, pos, cap, 0)
      case m_len >= lz77_min_match {
        True -> {
          let cmd =
            BrCommand(
              insert_len: pos - last_emit,
              copy_len: m_len,
              distance: distance,
            )
          let hashes =
            brotli_update_hashes(
              bytes,
              dict.insert(hashes, brotli_byte_key(bytes, pos), pos),
              pos + 1,
              pos + m_len,
              total,
            )
          lz77_match_loop(bytes, pos + m_len, total, pos + m_len, hashes, [
            cmd,
            ..commands_rev
          ])
        }
        False ->
          lz77_match_loop(
            bytes,
            pos + 1,
            total,
            last_emit,
            dict.insert(hashes, brotli_byte_key(bytes, pos), pos),
            commands_rev,
          )
      }
    }
  }
}

fn brotli_byte_key(bytes: BitArray, pos: Int) -> Int {
  let b0 = brotli_byte_at(bytes, pos)
  let b1 = brotli_byte_at(bytes, pos + 1)
  let b2 = brotli_byte_at(bytes, pos + 2)
  let b3 = brotli_byte_at(bytes, pos + 3)
  brotli_hash4(b0, b1, b2, b3)
}

fn brotli_hash4(b0: Int, b1: Int, b2: Int, b3: Int) -> Int {
  int.bitwise_and(
    int.bitwise_exclusive_or(
      int.bitwise_exclusive_or(b0 * 2_654_435_761, b1 * 40_503),
      int.bitwise_exclusive_or(b2 * 2_246_822_519, b3 * 374_761_393),
    ),
    0x3FFFF,
  )
}

fn brotli_byte_at(bytes: BitArray, pos: Int) -> Int {
  case bit_array.slice(bytes, pos, 1) {
    Ok(<<b>>) -> b
    _ -> 0
  }
}

fn brotli_match_len(
  bytes: BitArray,
  a: Int,
  b: Int,
  cap: Int,
  count: Int,
) -> Int {
  case count >= cap {
    True -> count
    False ->
      case
        brotli_byte_at(bytes, a + count) == brotli_byte_at(bytes, b + count)
      {
        True -> brotli_match_len(bytes, a, b, cap, count + 1)
        False -> count
      }
  }
}

fn brotli_update_hashes(
  bytes: BitArray,
  hashes: dict.Dict(Int, Int),
  start: Int,
  stop: Int,
  total: Int,
) -> dict.Dict(Int, Int) {
  case start >= stop || start + lz77_min_match > total {
    True -> hashes
    False ->
      brotli_update_hashes(
        bytes,
        dict.insert(hashes, brotli_byte_key(bytes, start), start),
        start + 1,
        stop,
        total,
      )
  }
}

// -- IC + distance code encoding --------------------------------------

fn lz77_pick_insert_code(insert_len: Int) -> #(Int, Int, Int) {
  let code = pick_insert_code_for_length(insert_len)
  let extras_bits = insert_extra_bits_for(code)
  let extras_value = insert_len - insert_base_offset(code)
  #(code, extras_bits, extras_value)
}

fn lz77_pick_copy_code(copy_len: Int) -> #(Int, Int, Int) {
  let code = pick_copy_code_for_length(copy_len)
  let extras_bits = copy_extra_bits_for(code)
  let extras_value = copy_len - copy_base_offset(code)
  #(code, extras_bits, extras_value)
}

fn pick_copy_code_for_length(copy_len: Int) -> Int {
  case copy_len {
    n if n <= 9 -> n - 2
    n if n <= 11 -> 8
    n if n <= 13 -> 9
    n if n <= 17 -> 10
    n if n <= 21 -> 11
    n if n <= 29 -> 12
    n if n <= 37 -> 13
    n if n <= 53 -> 14
    n if n <= 69 -> 15
    n if n <= 101 -> 16
    n if n <= 133 -> 17
    n if n <= 197 -> 18
    n if n <= 325 -> 19
    n if n <= 581 -> 20
    n if n <= 1093 -> 21
    n if n <= 2117 -> 22
    _ -> 23
  }
}

fn copy_extra_bits_for(code: Int) -> Int {
  case code {
    n if n <= 7 -> 0
    8 | 9 -> 1
    10 | 11 -> 2
    12 | 13 -> 3
    14 | 15 -> 4
    16 | 17 -> 5
    18 -> 6
    19 -> 7
    20 -> 8
    21 -> 9
    22 -> 10
    _ -> 24
  }
}

fn copy_base_offset(code: Int) -> Int {
  case code {
    n if n <= 7 -> 2 + n
    8 -> 10
    9 -> 12
    10 -> 14
    11 -> 18
    12 -> 22
    13 -> 30
    14 -> 38
    15 -> 54
    16 -> 70
    17 -> 102
    18 -> 134
    19 -> 198
    20 -> 326
    21 -> 582
    22 -> 1094
    _ -> 2118
  }
}

// IC symbol for an explicit-distance command (cell_idx ≥ 2).  Mirrors
// `cmd_lut_entry`'s decode: each cell carries 64 symbols, 8 insert
// sub-values × 8 copy sub-values.  The cell index is determined by
// the (insert_bucket, copy_bucket) pair where bucket = code / 8 * 8.
fn lz77_ic_symbol(insert_code: Int, copy_code: Int) -> Int {
  let insert_bucket = insert_code / 8 * 8
  let copy_bucket = copy_code / 8 * 8
  let cell_idx = lz77_cell_idx(insert_bucket, copy_bucket)
  let within = { insert_code % 8 } * 8 + { copy_code % 8 }
  cell_idx * 64 + within
}

fn lz77_cell_idx(insert_bucket: Int, copy_bucket: Int) -> Int {
  case insert_bucket, copy_bucket {
    0, 0 -> 2
    0, 8 -> 3
    8, 0 -> 4
    8, 8 -> 5
    0, 16 -> 6
    16, 0 -> 7
    8, 16 -> 8
    16, 8 -> 9
    _, _ -> 10
  }
}

// Distance code (NPOSTFIX=0, NDIRECT=0).  Per RFC 7932 §4 long
// distances start at code 16.  Returns the code in `16..63` and the
// extra bits/value to emit alongside it.
fn lz77_distance_code(d: Int) -> #(Int, Int, Int) {
  lz77_distance_code_loop(d, 0)
}

fn lz77_distance_code_loop(d: Int, g: Int) -> #(Int, Int, Int) {
  let bits = g / 2 + 1
  let half = g % 2
  let base = int.bitwise_shift_left(2 + half, bits) - 3
  let span = int.bitwise_shift_left(1, bits)
  case d >= base && d < base + span {
    True -> #(16 + g, bits, d - base)
    False -> lz77_distance_code_loop(d, g + 1)
  }
}

// -- Frequency tallying for the three Huffman alphabets ---------------

fn tally_literal_freqs(
  bytes: BitArray,
  commands: List(BrCommand),
  pos: Int,
  acc: dict.Dict(Int, Int),
) -> dict.Dict(Int, Int) {
  case commands {
    [] -> acc
    [cmd, ..rest] -> {
      let acc = tally_literal_range(bytes, pos, cmd.insert_len, acc)
      tally_literal_freqs(bytes, rest, pos + cmd.insert_len + cmd.copy_len, acc)
    }
  }
}

fn tally_literal_range(
  bytes: BitArray,
  pos: Int,
  count: Int,
  acc: dict.Dict(Int, Int),
) -> dict.Dict(Int, Int) {
  case count {
    0 -> acc
    _ -> {
      let byte = brotli_byte_at(bytes, pos)
      let cur = case dict.get(acc, byte) {
        Ok(v) -> v
        Error(_) -> 0
      }
      tally_literal_range(
        bytes,
        pos + 1,
        count - 1,
        dict.insert(acc, byte, cur + 1),
      )
    }
  }
}

fn tally_ic_freqs(
  commands: List(BrCommand),
  acc: dict.Dict(Int, Int),
) -> dict.Dict(Int, Int) {
  case commands {
    [] -> acc
    [cmd, ..rest] -> {
      let #(ic_sym, _, _, _, _) = derive_ic_fields(cmd)
      let cur = case dict.get(acc, ic_sym) {
        Ok(v) -> v
        Error(_) -> 0
      }
      tally_ic_freqs(rest, dict.insert(acc, ic_sym, cur + 1))
    }
  }
}

fn tally_distance_freqs(
  commands: List(BrCommand),
  acc: dict.Dict(Int, Int),
) -> dict.Dict(Int, Int) {
  case commands {
    [] -> acc
    [cmd, ..rest] ->
      case cmd.copy_len > 0 {
        False -> tally_distance_freqs(rest, acc)
        True -> {
          let #(code, _, _) = lz77_distance_code(cmd.distance)
          let cur = case dict.get(acc, code) {
            Ok(v) -> v
            Error(_) -> 0
          }
          tally_distance_freqs(rest, dict.insert(acc, code, cur + 1))
        }
      }
  }
}

// Returns (ic_symbol, ins_extra_bits, ins_extra_value,
// copy_extra_bits, copy_extra_value).  For terminal commands
// (copy_len == 0) we use copy_code 2 (copy_len 4, no extras) — the
// metablock will end after the insert step because state.remaining
// hits 0, so the copy_len value is never observed.  copy_code 2 lives
// in cell_idx 2's first row, so the IC symbol stays in the
// explicit-distance bucket and the decoder still expects one
// distance code, which we provide as distance 1 with no real copy.
fn derive_ic_fields(cmd: BrCommand) -> #(Int, Int, Int, Int, Int) {
  let #(insert_code, ins_bits, ins_value) =
    lz77_pick_insert_code(cmd.insert_len)
  let copy_len = case cmd.copy_len {
    0 -> 4
    n -> n
  }
  let #(copy_code, copy_bits, copy_value) = lz77_pick_copy_code(copy_len)
  let ic_sym = lz77_ic_symbol(insert_code, copy_code)
  #(ic_sym, ins_bits, ins_value, copy_bits, copy_value)
}

// -- Bitstream emission for the LZ77 metablock ------------------------

fn emit_lz77_metablock_body(
  writer: BitWriter,
  bytes: BitArray,
  mlen: Int,
  commands: List(BrCommand),
  lit_lengths: List(Int),
  lit_codes: dict.Dict(Int, #(Int, Int)),
  ic_lengths: List(Int),
  ic_codes: dict.Dict(Int, #(Int, Int)),
  dist_lengths: List(Int),
  dist_codes: dict.Dict(Int, #(Int, Int)),
) -> BitWriter {
  // ISLAST=1, ISLASTEMPTY=0.
  let writer = bw_write(writer, 1, 1)
  let writer = bw_write(writer, 0, 1)
  // MNIBBLES = 4 → 00; MLEN-1 in 16 bits.
  let writer = bw_write(writer, 0, 2)
  let writer = bw_write(writer, mlen - 1, 16)

  // NBLTYPES (L, I, D) = 1 each, encoded as a single 0 bit.
  let writer = bw_write(writer, 0, 1)
  let writer = bw_write(writer, 0, 1)
  let writer = bw_write(writer, 0, 1)

  // NPOSTFIX = 0, NDIRECT = 0.
  let writer = bw_write(writer, 0, 2)
  let writer = bw_write(writer, 0, 4)

  // Context mode for the single literal block type: LSB6 = 0.
  let writer = bw_write(writer, 0, 2)

  // NTREESL = NTREESD = 1, encoded as a 0 bit each.
  let writer = bw_write(writer, 0, 1)
  let writer = bw_write(writer, 0, 1)

  // Three complex-form Huffman descriptors.
  let writer = emit_complex_huffman_descriptor(writer, lit_lengths, 256)
  let writer = emit_complex_huffman_descriptor(writer, ic_lengths, 704)
  let writer = emit_complex_huffman_descriptor(writer, dist_lengths, 64)

  // Command stream.
  emit_lz77_commands(
    writer,
    bytes,
    0,
    commands,
    lit_codes,
    ic_codes,
    dist_codes,
  )
}

fn emit_lz77_commands(
  writer: BitWriter,
  bytes: BitArray,
  pos: Int,
  commands: List(BrCommand),
  lit_codes: dict.Dict(Int, #(Int, Int)),
  ic_codes: dict.Dict(Int, #(Int, Int)),
  dist_codes: dict.Dict(Int, #(Int, Int)),
) -> BitWriter {
  case commands {
    [] -> writer
    [cmd, ..rest] -> {
      let #(ic_sym, ins_bits, ins_value, copy_bits, copy_value) =
        derive_ic_fields(cmd)
      let writer = emit_huffman_symbol(writer, ic_codes, ic_sym)
      let writer = bw_write(writer, ins_value, ins_bits)
      let writer = bw_write(writer, copy_value, copy_bits)
      let writer =
        emit_literal_run(writer, bytes, pos, cmd.insert_len, lit_codes)
      let next_pos = pos + cmd.insert_len
      let writer = case cmd.copy_len {
        0 -> {
          // Synthetic copy_code still occupies a slot in cell_idx 2,
          // so the decoder still expects a distance code.  Use the
          // first available short-distance derived offset (code 16,
          // extras 0 = distance 1) — the copy is never executed
          // because state.remaining hits 0 after the insert step.
          let #(d_code, d_bits, d_value) = lz77_distance_code(1)
          let writer = emit_huffman_symbol(writer, dist_codes, d_code)
          bw_write(writer, d_value, d_bits)
        }
        _ -> {
          let #(d_code, d_bits, d_value) = lz77_distance_code(cmd.distance)
          let writer = emit_huffman_symbol(writer, dist_codes, d_code)
          bw_write(writer, d_value, d_bits)
        }
      }
      emit_lz77_commands(
        writer,
        bytes,
        next_pos + cmd.copy_len,
        rest,
        lit_codes,
        ic_codes,
        dist_codes,
      )
    }
  }
}

fn emit_literal_run(
  writer: BitWriter,
  bytes: BitArray,
  pos: Int,
  remaining: Int,
  codes: dict.Dict(Int, #(Int, Int)),
) -> BitWriter {
  case remaining {
    0 -> writer
    _ -> {
      let byte = brotli_byte_at(bytes, pos)
      let writer = emit_huffman_symbol(writer, codes, byte)
      emit_literal_run(writer, bytes, pos + 1, remaining - 1, codes)
    }
  }
}

fn emit_huffman_symbol(
  writer: BitWriter,
  codes: dict.Dict(Int, #(Int, Int)),
  symbol: Int,
) -> BitWriter {
  let #(code, length) = case dict.get(codes, symbol) {
    Ok(v) -> v
    Error(_) -> #(0, 0)
  }
  bw_write_code_msb_first(writer, code, length)
}

fn emit_empty_last_metablock(writer: BitWriter) -> BitWriter {
  // ISLAST=1, ISLASTEMPTY=1.
  let writer = bw_write(writer, 1, 1)
  bw_write(writer, 1, 1)
}

fn encode_chunks(
  writer: BitWriter,
  bytes: BitArray,
  consumed: Int,
  total: Int,
) -> BitWriter {
  let remaining = total - consumed
  case remaining <= 0 {
    True -> writer
    False -> {
      let chunk_size = case remaining > uncompressed_chunk_size {
        True -> uncompressed_chunk_size
        False -> remaining
      }
      let writer =
        emit_uncompressed_metablock(writer, bytes, consumed, chunk_size)
      encode_chunks(writer, bytes, consumed + chunk_size, total)
    }
  }
}

fn emit_uncompressed_metablock(
  writer: BitWriter,
  bytes: BitArray,
  offset: Int,
  chunk_size: Int,
) -> BitWriter {
  // ISLAST=0.
  let writer = bw_write(writer, 0, 1)
  // MNIBBLES: 2-bit field, value `N-4` (so 0 → 4 nibbles = 16-bit
  // MLEN-1).
  let writer = bw_write(writer, 0, 2)
  // MLEN - 1 in 16 bits.
  let writer = bw_write(writer, chunk_size - 1, 16)
  // ISUNCOMPRESSED = 1.
  let writer = bw_write(writer, 1, 1)
  // Align to byte boundary before raw bytes.
  let writer = bw_align(writer)
  let assert Ok(chunk) = bit_array.slice(bytes, offset, chunk_size)
  bw_append_bytes(writer, chunk)
}

// -- LSB-first bit writer for brotli encode ----------------------------
//
// Mirrors the LSB-first convention `read_bits` uses on the decoder
// side: bytes are written low-byte first, and within a byte the
// least-significant bit comes from the first call.

type BitWriter {
  BitWriter(bytes_rev: List(Int), buffer: Int, bits: Int)
}

fn new_bit_writer() -> BitWriter {
  BitWriter(bytes_rev: [], buffer: 0, bits: 0)
}

fn bw_write(writer: BitWriter, value: Int, count: Int) -> BitWriter {
  case count {
    0 -> writer
    _ -> {
      let masked = int.bitwise_and(value, bw_mask(count))
      let new_buffer =
        int.bitwise_or(
          writer.buffer,
          int.bitwise_shift_left(masked, writer.bits),
        )
      bw_flush_bytes(BitWriter(
        bytes_rev: writer.bytes_rev,
        buffer: new_buffer,
        bits: writer.bits + count,
      ))
    }
  }
}

fn bw_mask(count: Int) -> Int {
  int.bitwise_shift_left(1, count) - 1
}

fn bw_flush_bytes(writer: BitWriter) -> BitWriter {
  case writer.bits >= 8 {
    False -> writer
    True -> {
      let byte = int.bitwise_and(writer.buffer, 0xFF)
      bw_flush_bytes(BitWriter(
        bytes_rev: [byte, ..writer.bytes_rev],
        buffer: int.bitwise_shift_right(writer.buffer, 8),
        bits: writer.bits - 8,
      ))
    }
  }
}

fn bw_align(writer: BitWriter) -> BitWriter {
  case writer.bits {
    0 -> writer
    _ -> bw_write(writer, 0, 8 - writer.bits)
  }
}

fn bw_append_bytes(writer: BitWriter, chunk: BitArray) -> BitWriter {
  let writer = bw_align(writer)
  // After align, buffer is empty; just push raw bytes.
  bw_push_raw(writer, chunk)
}

fn bw_push_raw(writer: BitWriter, chunk: BitArray) -> BitWriter {
  case chunk {
    <<b, rest:bytes>> ->
      bw_push_raw(BitWriter(..writer, bytes_rev: [b, ..writer.bytes_rev]), rest)
    _ -> writer
  }
}

fn bw_flush(writer: BitWriter) -> BitArray {
  let writer = case writer.bits {
    0 -> writer
    _ -> {
      // Pad the trailing partial byte with zeros to complete it.
      let byte = int.bitwise_and(writer.buffer, 0xFF)
      BitWriter(bytes_rev: [byte, ..writer.bytes_rev], buffer: 0, bits: 0)
    }
  }
  bw_bytes_to_bit_array(list.reverse(writer.bytes_rev), <<>>)
}

fn bw_bytes_to_bit_array(values: List(Int), acc: BitArray) -> BitArray {
  case values {
    [] -> acc
    [head, ..rest] -> bw_bytes_to_bit_array(rest, <<acc:bits, head>>)
  }
}

/// Decode a Brotli stream using default limits.
pub fn decode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  decode_with_limits(bytes: bytes, limits: limit.default())
}

/// Decode a Brotli stream using explicit limits.
pub fn decode_with_limits(
  bytes bytes: BitArray,
  limits limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  use <- bool.guard(
    when: bit_array.byte_size(bytes) > limit.max_input_bytes(limits),
    return: Error(error.CodecLimitExceeded(
      limit: "max_input_bytes",
      actual: bit_array.byte_size(bytes),
    )),
  )

  let reader = new_reader(bytes)
  use #(_wbits, reader) <- result.try(read_wbits(reader))
  decode_metablocks(reader, <<>>, new_ring(), limits)
}

// -- metablock loop -----------------------------------------------------

fn decode_metablocks(
  reader: Reader,
  output: BitArray,
  ring: DistRing,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  use #(is_last, reader) <- result.try(read_bits(reader, 1))
  case is_last {
    1 -> {
      use #(is_last_empty, reader) <- result.try(read_bits(reader, 1))
      case is_last_empty {
        1 -> Ok(output)
        _ -> {
          use #(output, _ring, _reader) <- result.try(decode_one_metablock(
            reader,
            output,
            ring,
            limits,
            True,
          ))
          Ok(output)
        }
      }
    }
    _ -> {
      use #(output, ring, reader) <- result.try(decode_one_metablock(
        reader,
        output,
        ring,
        limits,
        False,
      ))
      decode_metablocks(reader, output, ring, limits)
    }
  }
}

fn decode_one_metablock(
  reader: Reader,
  output: BitArray,
  ring: DistRing,
  limits: limit.Limits,
  is_last: Bool,
) -> Result(#(BitArray, DistRing, Reader), error.CodecError) {
  use #(mnibbles_raw, reader) <- result.try(read_bits(reader, 2))
  let mnibbles = case mnibbles_raw {
    0 -> 4
    1 -> 5
    2 -> 6
    _ -> 0
  }
  case mnibbles {
    0 -> decode_skip_metablock(reader, output, ring)
    _ -> decode_sized_metablock(reader, output, ring, limits, is_last, mnibbles)
  }
}

fn decode_sized_metablock(
  reader: Reader,
  output: BitArray,
  ring: DistRing,
  limits: limit.Limits,
  is_last: Bool,
  mnibbles: Int,
) -> Result(#(BitArray, DistRing, Reader), error.CodecError) {
  use #(mlen_minus_1, reader) <- result.try(read_bits(reader, mnibbles * 4))
  let mlen = mlen_minus_1 + 1
  use #(is_uncompressed, reader) <- result.try(case is_last {
    True -> Ok(#(0, reader))
    False -> read_bits(reader, 1)
  })
  case is_uncompressed {
    1 -> decode_uncompressed_metablock(reader, output, ring, mlen, limits)
    _ -> decode_compressed_metablock(reader, output, ring, mlen, limits)
  }
}

// -- Compressed metablock (RFC 7932 §9.2) ------------------------------
//
// Parses the full header, builds the three prefix codes, then enters
// the command loop in `run_commands`.  Block switching (NBLTYPES > 1),
// context maps (NTREES > 1), and static-dictionary references with
// the full RFC 7932 transform set are all handled here.

fn decode_compressed_metablock(
  reader: Reader,
  output: BitArray,
  ring: DistRing,
  mlen: Int,
  limits: limit.Limits,
) -> Result(#(BitArray, DistRing, Reader), error.CodecError) {
  use #(nbl_literal, reader) <- result.try(decode_var_len_uint8(reader))
  use #(nbl_command, reader) <- result.try(decode_var_len_uint8(reader))
  use #(nbl_distance, reader) <- result.try(decode_var_len_uint8(reader))

  use #(block_l, reader) <- result.try(read_block_state(reader, nbl_literal))
  use #(block_i, reader) <- result.try(read_block_state(reader, nbl_command))
  use #(block_d, reader) <- result.try(read_block_state(reader, nbl_distance))

  use #(npostfix, reader) <- result.try(read_bits(reader, 2))
  use #(ndirect_code, reader) <- result.try(read_bits(reader, 4))
  let ndirect = int.bitwise_shift_left(ndirect_code, npostfix)

  use #(context_modes, reader) <- result.try(
    read_context_modes(reader, nbl_literal, []),
  )

  use #(ntrees_literal, reader) <- result.try(decode_var_len_uint8(reader))
  use #(literal_context_map, reader) <- result.try(decode_context_map(
    reader,
    ntrees_literal,
    nbl_literal * 64,
  ))

  use #(ntrees_distance, reader) <- result.try(decode_var_len_uint8(reader))
  use #(distance_context_map, reader) <- result.try(decode_context_map(
    reader,
    ntrees_distance,
    nbl_distance * 4,
  ))

  let literal_alphabet = 256
  let command_alphabet = 704
  let distance_alphabet = 16 + ndirect + int.bitwise_shift_left(48, npostfix)

  use #(literal_codes, reader) <- result.try(
    decode_prefix_codes(reader, ntrees_literal, literal_alphabet, "literal", []),
  )
  use #(command_codes, reader) <- result.try(
    decode_prefix_codes(
      reader,
      nbl_command,
      command_alphabet,
      "insert-and-copy",
      [],
    ),
  )
  use #(distance_codes, reader) <- result.try(
    decode_prefix_codes(
      reader,
      ntrees_distance,
      distance_alphabet,
      "distance",
      [],
    ),
  )

  let pos = bit_array.byte_size(output)
  let state =
    CommandState(
      output: output,
      ring: ring,
      remaining: mlen,
      literal_codes: literal_codes,
      command_codes: command_codes,
      distance_codes: distance_codes,
      npostfix: npostfix,
      ndirect: ndirect,
      context_modes: context_modes,
      literal_context_map: literal_context_map,
      distance_context_map: distance_context_map,
      block_l: block_l,
      block_i: block_i,
      block_d: block_d,
      prev1: byte_at_or_zero(output, pos - 1),
      prev2: byte_at_or_zero(output, pos - 2),
      limits: limits,
    )
  use #(new_output, new_ring, reader) <- result.try(run_commands(reader, state))
  Ok(#(new_output, new_ring, reader))
}

fn byte_at_or_zero(bytes: BitArray, idx: Int) -> Int {
  case idx < 0 {
    True -> 0
    False ->
      case bit_array.slice(bytes, idx, 1) {
        Ok(<<b>>) -> b
        _ -> 0
      }
  }
}

// -- Distance ring buffer (RFC 7932 §4) --------------------------------

/// Brotli's 4-entry recent-distance buffer.  `idx` advances on every
/// recorded distance; reading the kᵗʰ-most-recent distance uses
/// `slots[(idx - 1 - k) & 3]`.  Initial values from RFC 7932 §4.
type DistRing {
  DistRing(idx: Int, d0: Int, d1: Int, d2: Int, d3: Int)
}

fn new_ring() -> DistRing {
  DistRing(idx: 0, d0: 16, d1: 15, d2: 11, d3: 4)
}

fn ring_get(r: DistRing, slot: Int) -> Int {
  case int.bitwise_and(slot, 3) {
    0 -> r.d0
    1 -> r.d1
    2 -> r.d2
    _ -> r.d3
  }
}

fn ring_set(r: DistRing, slot: Int, value: Int) -> DistRing {
  case int.bitwise_and(slot, 3) {
    0 -> DistRing(..r, d0: value)
    1 -> DistRing(..r, d1: value)
    2 -> DistRing(..r, d2: value)
    _ -> DistRing(..r, d3: value)
  }
}

/// Write `distance` to the current slot then advance `idx`.  This is
/// the post-decode step for every command's distance, including the
/// reused "code 0" case (where the same value is written back).
fn ring_push(ring: DistRing, distance: Int) -> DistRing {
  let updated = ring_set(ring, ring.idx, distance)
  DistRing(..updated, idx: updated.idx + 1)
}

// -- Command loop (RFC 7932 §4) ----------------------------------------
//
// One pass through the metablock body emits literals and copies until
// MLEN bytes have been produced.  Each iteration:
//
//   1. Decode an insert-and-copy symbol from the command prefix code
//      and turn it into `(insert_len, copy_len, dist_code, context)`
//      via `cmd_lut`.
//   2. Read `insert_len_extra` and `copy_len_extra` bits.
//   3. Emit `insert_len` literals from the literal prefix code.
//   4. If we still have bytes to produce, decode a distance code from
//      the distance prefix code (unless the I+C entry's `dist_code`
//      is `-1`, meaning "reuse the most recent distance"), resolve it
//      against the ring buffer, and copy `copy_len` bytes from
//      `output[pos - distance ..]`.
//
// The runtime state for one metablock is bundled in `CommandState` so
// the (already pretty long) command-loop recurrences stay readable.

type CommandState {
  CommandState(
    output: BitArray,
    ring: DistRing,
    remaining: Int,
    literal_codes: List(PrefixCode),
    command_codes: List(PrefixCode),
    distance_codes: List(PrefixCode),
    npostfix: Int,
    ndirect: Int,
    context_modes: List(Int),
    /// `nbl_literal × 64` entries (or empty when NTREESL = 1).  Indexed
    /// by `block_type_l × 64 + literal_context_id`.
    literal_context_map: BitArray,
    /// `nbl_distance × 4` entries (or empty when NTREESD = 1).  Indexed
    /// by `block_type_d × 4 + distance_context`.
    distance_context_map: BitArray,
    block_l: BlockState,
    block_i: BlockState,
    block_d: BlockState,
    /// Most recent literal byte (for context computation).
    prev1: Int,
    /// Second-most-recent literal byte.
    prev2: Int,
    limits: limit.Limits,
  )
}

/// Per-category block-switching state.  When `nbltypes == 1`, no
/// switching ever happens: `length` is set high enough to never tick
/// down to zero within a metablock, and the type/length codes are
/// `None`.  Otherwise we maintain a 2-entry "ring buffer" of recent
/// block types so the next switch's `(0, 1, n+2)` encoding can
/// resolve to the right new type.
type BlockState {
  BlockState(
    type_: Int,
    length: Int,
    nbltypes: Int,
    type_code: Option(PrefixCode),
    length_code: Option(PrefixCode),
    rb_prev: Int,
    rb_curr: Int,
  )
}

fn trivial_block_state() -> BlockState {
  BlockState(
    type_: 0,
    length: 0x7FFF_FFFF,
    nbltypes: 1,
    type_code: None,
    length_code: None,
    rb_prev: 1,
    rb_curr: 0,
  )
}

fn run_commands(
  reader: Reader,
  state: CommandState,
) -> Result(#(BitArray, DistRing, Reader), error.CodecError) {
  case state.remaining <= 0 {
    True -> Ok(#(state.output, state.ring, reader))
    False -> {
      use #(block_i, reader) <- result.try(maybe_switch_block(
        reader,
        state.block_i,
      ))
      let state = CommandState(..state, block_i: block_i)
      let command_tree =
        pick_tree_by_index(state.command_codes, state.block_i.type_)
      use #(cmd, reader) <- result.try(decode_command(reader, command_tree))
      use #(state, reader) <- result.try(emit_literals(
        reader,
        state,
        cmd.insert_len,
      ))
      case state.remaining <= 0 {
        True -> Ok(#(state.output, state.ring, reader))
        False -> execute_copy_step(reader, state, cmd)
      }
    }
  }
}

fn execute_copy_step(
  reader: Reader,
  state: CommandState,
  cmd: Command,
) -> Result(#(BitArray, DistRing, Reader), error.CodecError) {
  use #(distance, push_to_ring, state, reader) <- result.try(
    decode_distance_value(reader, state, cmd),
  )
  let pos = bit_array.byte_size(state.output)
  let is_dict_ref = distance > pos
  let ring = case push_to_ring && !is_dict_ref {
    True -> ring_push(state.ring, distance)
    False -> state.ring
  }
  let state = CommandState(..state, ring: ring)
  use state <- result.try(perform_copy(state, distance, cmd.copy_len, pos))
  run_commands(reader, state)
}

/// Decode the command's distance and report whether normal in-window
/// copies should push it onto the ring buffer.  Matches brotli's
/// `kCmdLut[].distance_code` convention:
///
/// * `0` — implicit reuse: take the most-recent distance from the
///   ring buffer and DO NOT advance it (the slot already holds that
///   value).  Used when the I+C `cell_idx < 2`.
/// * `-1` — read a distance code from the distance prefix tree and
///   resolve it via short-code, direct, or long-code paths.  Used
///   when the I+C `cell_idx ≥ 2`.
fn decode_distance_value(
  reader: Reader,
  state: CommandState,
  cmd: Command,
) -> Result(#(Int, Bool, CommandState, Reader), error.CodecError) {
  case cmd.distance_code {
    0 -> {
      // Implicit reuse — no distance bits in the stream, no block tick.
      let distance = ring_get(state.ring, state.ring.idx - 1)
      Ok(#(distance, False, state, reader))
    }
    _ -> read_distance_code(reader, state, cmd)
  }
}

fn read_distance_code(
  reader: Reader,
  state: CommandState,
  cmd: Command,
) -> Result(#(Int, Bool, CommandState, Reader), error.CodecError) {
  use #(block_d, reader) <- result.try(maybe_switch_block(reader, state.block_d))
  let state = CommandState(..state, block_d: block_d)
  let distance_tree =
    pick_tree_by_index(
      state.distance_codes,
      select_distance_tree_idx(state, cmd.distance_context),
    )
  use #(code, reader) <- result.try(decode_prefix_symbol(reader, distance_tree))
  case code < 16 {
    True -> {
      let #(distance, push) = short_distance(code, state.ring)
      Ok(#(distance, push, state, reader))
    }
    False ->
      case code < 16 + state.ndirect {
        True -> Ok(#(code - 15, True, state, reader))
        False -> {
          use #(distance, push, reader) <- result.try(apply_long_distance(
            reader,
            code,
            state.npostfix,
            state.ndirect,
          ))
          Ok(#(distance, push, state, reader))
        }
      }
  }
}

fn short_distance(code: Int, ring: DistRing) -> #(Int, Bool) {
  case code <= 3 {
    True -> {
      // Codes 0..3 read the kᵗʰ-most-recent distance.  Code 0 reuses
      // the slot the ring already holds, so we skip the ring push.
      let offset = code - 3
      let distance = ring_get(ring, ring.idx - offset)
      #(distance, code != 0)
    }
    False -> {
      // Codes 4..15: six derived offsets from ring[0] or ring[3].
      // delta table from C `0x605142` packed-nibble lookup.
      let #(base, index_delta) = case code < 10 {
        True -> #(code - 4, 3)
        False -> #(code - 10, 2)
      }
      let pre_delta =
        int.bitwise_and(int.bitwise_shift_right(0x60_5142, 4 * base), 0xF)
      let delta = pre_delta - 3
      let distance = ring_get(ring, ring.idx + index_delta) + delta
      #(distance, True)
    }
  }
}

/// Long-distance branch: read `extra_bits` extra bits and combine with
/// the per-code base offset.  Returns `push_to_ring = True`; the
/// caller suppresses the push if the resolved distance turns out to
/// be a static-dictionary reference.
fn apply_long_distance(
  reader: Reader,
  distance_code: Int,
  npostfix: Int,
  ndirect: Int,
) -> Result(#(Int, Bool, Reader), error.CodecError) {
  let #(extra_bits, base) =
    long_distance_params(distance_code, npostfix, ndirect)
  use #(extra, reader) <- result.try(read_bits(reader, extra_bits))
  let distance = base + int.bitwise_shift_left(extra, npostfix)
  Ok(#(distance, True, reader))
}

/// Per RFC 7932 §4 the long-distance code group `g` (counting from 0)
/// has `bits = g/2 + 1` extra bits.  Each group holds `2^npostfix`
/// codes that share `bits` and differ in their low `npostfix` bits.
/// The base offset for group `g`, sub-code `j`, is
///   NDIRECT + (((2 + (g % 2)) << bits - 4) << npostfix) + 1 + j
fn long_distance_params(code: Int, npostfix: Int, ndirect: Int) -> #(Int, Int) {
  let postfix = int.bitwise_shift_left(1, npostfix)
  let i_relative = code - 16 - ndirect
  let group_idx = i_relative / postfix
  let within_group = i_relative % postfix
  let bits = group_idx / 2 + 1
  let half = group_idx % 2
  let pre = int.bitwise_shift_left(2 + half, bits) - 4
  let base = ndirect + int.bitwise_shift_left(pre, npostfix) + 1 + within_group
  #(bits, base)
}

fn perform_copy(
  state: CommandState,
  distance: Int,
  copy_len: Int,
  pos: Int,
) -> Result(CommandState, error.CodecError) {
  case distance > pos {
    True -> dictionary_copy(state, distance, copy_len, pos)
    False -> in_window_copy(state, distance, copy_len, pos)
  }
}

fn in_window_copy(
  state: CommandState,
  distance: Int,
  copy_len: Int,
  pos: Int,
) -> Result(CommandState, error.CodecError) {
  let actual = int.min(copy_len, state.remaining)
  let new_output = lz77_copy(state.output, distance, actual, pos)
  let projected = bit_array.byte_size(new_output)
  use <- bool.guard(
    when: projected > limit.max_output_bytes(state.limits),
    return: Error(error.CodecLimitExceeded(
      limit: "max_output_bytes",
      actual: projected,
    )),
  )
  Ok(refresh_prev_bytes(
    CommandState(
      ..state,
      output: new_output,
      remaining: state.remaining - actual,
    ),
  ))
}

/// Resolve a copy whose distance exceeds the current output position
/// against the RFC 7932 §8 static dictionary.  `address = distance -
/// pos - 1` is split into a word index (low `size_bits(copy_len)`
/// bits) and a transform index (the rest).  The selected dictionary
/// word is run through the chosen transform — which may add a prefix
/// or suffix, omit characters at either end, or uppercase part of the
/// word — and the resulting bytes are appended to the output.
fn dictionary_copy(
  state: CommandState,
  distance: Int,
  copy_len: Int,
  pos: Int,
) -> Result(CommandState, error.CodecError) {
  let shift = brotli_dict.size_bits(copy_len)
  use <- bool.guard(
    when: shift == 0,
    return: Error(error.CodecInvalidData(
      message: "brotli dictionary reference at length "
      <> int.to_string(copy_len)
      <> " (valid range 4..24)",
    )),
  )
  let address = distance - pos - 1
  let mask = int.bitwise_shift_left(1, shift) - 1
  let word_idx = int.bitwise_and(address, mask)
  let transform_idx = int.bitwise_shift_right(address, shift)
  use <- bool.guard(
    when: transform_idx >= brotli_xfm.num_transforms,
    return: Error(error.CodecInvalidData(
      message: "brotli dictionary transform index "
      <> int.to_string(transform_idx)
      <> " out of range",
    )),
  )
  let dict_offset = brotli_dict.offset(copy_len) + word_idx * copy_len
  let assert Ok(word) = bit_array.slice(brotli_dict.data, dict_offset, copy_len)
  let transformed = brotli_xfm.apply(word, transform_idx)
  let transformed_len = bit_array.byte_size(transformed)
  let truncated_len = int.min(transformed_len, state.remaining)
  let actual_bytes = case truncated_len == transformed_len {
    True -> transformed
    False -> {
      let assert Ok(slice) = bit_array.slice(transformed, 0, truncated_len)
      slice
    }
  }
  let new_output = bit_array.concat([state.output, actual_bytes])
  let projected = bit_array.byte_size(new_output)
  use <- bool.guard(
    when: projected > limit.max_output_bytes(state.limits),
    return: Error(error.CodecLimitExceeded(
      limit: "max_output_bytes",
      actual: projected,
    )),
  )
  Ok(refresh_prev_bytes(
    CommandState(
      ..state,
      output: new_output,
      remaining: state.remaining - truncated_len,
    ),
  ))
}

/// LZ77-style self-overlapping copy: emit `count` bytes by reading
/// `output[pos - distance]` and appending it, then incrementing pos.
/// Works correctly for `distance < count` because each emitted byte
/// updates the source.
fn lz77_copy(
  output: BitArray,
  distance: Int,
  count: Int,
  pos: Int,
) -> BitArray {
  case count {
    0 -> output
    _ -> {
      let src = pos - distance
      let assert Ok(<<byte>>) = bit_array.slice(output, src, 1)
      lz77_copy(<<output:bits, byte>>, distance, count - 1, pos + 1)
    }
  }
}

/// Emit `count` literals decoded one by one from the literal prefix
/// code.  Honours the metablock's `remaining` budget.
fn emit_literals(
  reader: Reader,
  state: CommandState,
  count: Int,
) -> Result(#(CommandState, Reader), error.CodecError) {
  let actual = int.min(count, state.remaining)
  emit_literals_loop(reader, state, actual)
}

// Per-iteration outcome of the literal-emit loop.  The loop dispatches
// on this; the recursive call stays in tail position so the Gleam JS
// compiler emits a real `while`, avoiding the ~10 000-frame call-stack
// limit (`use <- result.try(...)` or mutual recursion would otherwise
// grow the stack per iteration).
type LiteralStep {
  LiteralDone(state: CommandState, reader: Reader)
  LiteralContinue(state: CommandState, reader: Reader, remaining: Int)
  LiteralFailed(error: error.CodecError)
}

fn emit_literals_loop(
  reader: Reader,
  state: CommandState,
  remaining: Int,
) -> Result(#(CommandState, Reader), error.CodecError) {
  case remaining {
    0 -> Ok(#(state, reader))
    _ ->
      case emit_one_literal_step(reader, state, remaining) {
        LiteralFailed(e) -> Error(e)
        LiteralDone(s, r) -> Ok(#(s, r))
        LiteralContinue(s, r, rem) -> emit_literals_loop(r, s, rem)
      }
  }
}

fn emit_one_literal_step(
  reader: Reader,
  state: CommandState,
  remaining: Int,
) -> LiteralStep {
  case maybe_switch_block(reader, state.block_l) {
    Error(e) -> LiteralFailed(e)
    Ok(#(block_l, reader)) ->
      decode_one_literal(
        reader,
        CommandState(..state, block_l: block_l),
        remaining,
      )
  }
}

fn decode_one_literal(
  reader: Reader,
  state: CommandState,
  remaining: Int,
) -> LiteralStep {
  let tree =
    pick_tree_by_index(state.literal_codes, select_literal_tree_idx(state))
  case decode_prefix_symbol(reader, tree) {
    Error(e) -> LiteralFailed(e)
    Ok(#(byte, reader)) -> append_one_literal(reader, state, remaining, byte)
  }
}

fn append_one_literal(
  reader: Reader,
  state: CommandState,
  remaining: Int,
  byte: Int,
) -> LiteralStep {
  let projected = bit_array.byte_size(state.output) + 1
  case projected > limit.max_output_bytes(state.limits) {
    True ->
      LiteralFailed(error.CodecLimitExceeded(
        limit: "max_output_bytes",
        actual: projected,
      ))
    False -> {
      let new_state =
        CommandState(
          ..state,
          output: <<state.output:bits, byte>>,
          remaining: state.remaining - 1,
          prev2: state.prev1,
          prev1: byte,
        )
      LiteralContinue(new_state, reader, remaining - 1)
    }
  }
}

// -- Context-driven tree selection (RFC 7932 §7.3) ---------------------

fn select_literal_tree_idx(state: CommandState) -> Int {
  let block_type = state.block_l.type_
  let context_mode = pick_int_by_index(state.context_modes, block_type)
  let ctx = brotli_ctx.context_id(context_mode, state.prev1, state.prev2)
  case bit_array.byte_size(state.literal_context_map) {
    0 -> 0
    _ ->
      byte_at_or_zero(
        state.literal_context_map,
        int.bitwise_shift_left(block_type, 6) + ctx,
      )
  }
}

fn select_distance_tree_idx(state: CommandState, distance_context: Int) -> Int {
  let block_type = state.block_d.type_
  case bit_array.byte_size(state.distance_context_map) {
    0 -> 0
    _ ->
      byte_at_or_zero(
        state.distance_context_map,
        int.bitwise_shift_left(block_type, 2) + distance_context,
      )
  }
}

fn pick_int_by_index(values: List(Int), idx: Int) -> Int {
  case values, idx {
    [head, ..], 0 -> head
    [_, ..tail], _ -> pick_int_by_index(tail, idx - 1)
    [], _ -> 0
  }
}

fn pick_tree_by_index(trees: List(PrefixCode), idx: Int) -> PrefixCode {
  case trees, idx {
    [head, ..], 0 -> head
    [_, ..tail], _ -> pick_tree_by_index(tail, idx - 1)
    [], _ -> {
      let assert [head, ..] = trees
      head
    }
  }
}

// -- Update copy bookkeeping with `prev1`/`prev2` from the tail of the
//    copy or dictionary insert.  Called by `in_window_copy` and
//    `dictionary_copy` after the output buffer has grown.

fn refresh_prev_bytes(state: CommandState) -> CommandState {
  let pos = bit_array.byte_size(state.output)
  CommandState(
    ..state,
    prev1: byte_at_or_zero(state.output, pos - 1),
    prev2: byte_at_or_zero(state.output, pos - 2),
  )
}

// -- Insert-and-copy alphabet (RFC 7932 §5 / brotli `kCmdLut`) ---------

type Command {
  Command(
    insert_len: Int,
    copy_len: Int,
    /// `-1` for "no distance code follows; reuse most recent
    /// distance"; `0` for "decode a distance code".  Mirrors brotli's
    /// `kCmdLut[code].distance_code` field.
    distance_code: Int,
    distance_context: Int,
  )
}

fn decode_command(
  reader: Reader,
  code: PrefixCode,
) -> Result(#(Command, Reader), error.CodecError) {
  use #(symbol, reader) <- result.try(decode_prefix_symbol(reader, code))
  let lut = cmd_lut_entry(symbol)
  use #(ins_extra, reader) <- result.try(read_bits(reader, lut.ins_extra_bits))
  use #(copy_extra, reader) <- result.try(read_bits(reader, lut.copy_extra_bits))
  let command =
    Command(
      insert_len: lut.ins_offset + ins_extra,
      copy_len: lut.copy_offset + copy_extra,
      distance_code: lut.distance_code,
      distance_context: lut.context,
    )
  Ok(#(command, reader))
}

type CmdLut {
  CmdLut(
    ins_extra_bits: Int,
    copy_extra_bits: Int,
    distance_code: Int,
    context: Int,
    ins_offset: Int,
    copy_offset: Int,
  )
}

/// Compute the `kCmdLut`-equivalent entry for an insert-and-copy
/// symbol (0..703).  Algorithm matches `BrotliDecoderInitCmdLut` in
/// `brotli/c/dec/prefix.c`:
///
///   cell_idx = symbol >> 6
///   cell_pos = kCellPos[cell_idx]
///   copy_code   = ((cell_pos << 3) & 0x18) | (symbol & 0x7)
///   insert_code = (cell_pos & 0x18) | ((symbol >> 3) & 0x7)
///
/// distance_code = -1 for cell_idx ≥ 2 (literal-and-copy with reused
/// distance), 0 otherwise.  context = 3 when copy_offset > 4, else
/// copy_offset - 2.
fn cmd_lut_entry(symbol: Int) -> CmdLut {
  let cell_idx = int.bitwise_shift_right(symbol, 6)
  let cell_pos = cell_pos_table(cell_idx)
  let copy_code =
    int.bitwise_or(
      int.bitwise_and(int.bitwise_shift_left(cell_pos, 3), 0x18),
      int.bitwise_and(symbol, 0x7),
    )
  let insert_code =
    int.bitwise_or(
      int.bitwise_and(cell_pos, 0x18),
      int.bitwise_and(int.bitwise_shift_right(symbol, 3), 0x7),
    )
  let copy_off = cumulative_copy_offset(copy_code)
  let dist_code = case cell_idx >= 2 {
    True -> -1
    False -> 0
  }
  let context = case copy_off > 4 {
    True -> 3
    False -> copy_off - 2
  }
  CmdLut(
    ins_extra_bits: insert_extra_bits(insert_code),
    copy_extra_bits: copy_extra_bits(copy_code),
    distance_code: dist_code,
    context: context,
    ins_offset: cumulative_insert_offset(insert_code),
    copy_offset: copy_off,
  )
}

fn cell_pos_table(idx: Int) -> Int {
  case idx {
    0 -> 0
    1 -> 1
    2 -> 0
    3 -> 1
    4 -> 8
    5 -> 9
    6 -> 2
    7 -> 16
    8 -> 10
    9 -> 17
    _ -> 18
  }
}

fn insert_extra_bits(code: Int) -> Int {
  case code {
    0 | 1 | 2 | 3 | 4 | 5 -> 0
    6 | 7 -> 1
    8 | 9 -> 2
    10 | 11 -> 3
    12 | 13 -> 4
    14 | 15 -> 5
    16 -> 6
    17 -> 7
    18 -> 8
    19 -> 9
    20 -> 10
    21 -> 12
    22 -> 14
    _ -> 24
  }
}

fn copy_extra_bits(code: Int) -> Int {
  case code {
    0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 -> 0
    8 | 9 -> 1
    10 | 11 -> 2
    12 | 13 -> 3
    14 | 15 -> 4
    16 | 17 -> 5
    18 -> 6
    19 -> 7
    20 -> 8
    21 -> 9
    22 -> 10
    _ -> 24
  }
}

fn cumulative_insert_offset(target: Int) -> Int {
  cumulative_offset_loop(0, 0, target, insert_extra_bits)
}

fn cumulative_copy_offset(target: Int) -> Int {
  cumulative_offset_loop(2, 0, target, copy_extra_bits)
}

fn cumulative_offset_loop(
  cur: Int,
  idx: Int,
  target: Int,
  extra: fn(Int) -> Int,
) -> Int {
  case idx == target {
    True -> cur
    False ->
      cumulative_offset_loop(
        cur + int.bitwise_shift_left(1, extra(idx)),
        idx + 1,
        target,
        extra,
      )
  }
}

/// Read the block-switching trees and initial block-length for a
/// category.  For `nbltypes == 1` no bits are read — block switching
/// is disabled and the trivial state is returned.
fn read_block_state(
  reader: Reader,
  nbltypes: Int,
) -> Result(#(BlockState, Reader), error.CodecError) {
  case nbltypes <= 1 {
    True -> Ok(#(trivial_block_state(), reader))
    False -> read_active_block_state(reader, nbltypes)
  }
}

fn read_active_block_state(
  reader: Reader,
  nbltypes: Int,
) -> Result(#(BlockState, Reader), error.CodecError) {
  use #(type_code, reader) <- result.try(decode_prefix_code(
    reader,
    nbltypes + 2,
    "block-type",
  ))
  use #(length_code, reader) <- result.try(decode_prefix_code(
    reader,
    26,
    "block-length",
  ))
  use #(length, reader) <- result.try(read_block_length(reader, length_code))
  Ok(#(
    BlockState(
      type_: 0,
      length: length,
      nbltypes: nbltypes,
      type_code: Some(type_code),
      length_code: Some(length_code),
      rb_prev: 1,
      rb_curr: 0,
    ),
    reader,
  ))
}

fn read_block_length(
  reader: Reader,
  code: PrefixCode,
) -> Result(#(Int, Reader), error.CodecError) {
  use #(symbol, reader) <- result.try(decode_prefix_symbol(reader, code))
  let #(offset, nbits) = block_length_range(symbol)
  use #(extra, reader) <- result.try(read_bits(reader, nbits))
  Ok(#(offset + extra, reader))
}

/// `_kBrotliPrefixCodeRanges` from `c/common/constants.c`.  Indexed by
/// the 26-symbol block-length alphabet; returns the `(offset, nbits)`
/// pair used to compute `length = offset + extra` where `extra` is an
/// `nbits`-bit unsigned value following the symbol.
fn block_length_range(symbol: Int) -> #(Int, Int) {
  case symbol {
    0 -> #(1, 2)
    1 -> #(5, 2)
    2 -> #(9, 2)
    3 -> #(13, 2)
    4 -> #(17, 3)
    5 -> #(25, 3)
    6 -> #(33, 3)
    7 -> #(41, 3)
    8 -> #(49, 4)
    9 -> #(65, 4)
    10 -> #(81, 4)
    11 -> #(97, 4)
    12 -> #(113, 5)
    13 -> #(145, 5)
    14 -> #(177, 5)
    15 -> #(209, 5)
    16 -> #(241, 6)
    17 -> #(305, 6)
    18 -> #(369, 7)
    19 -> #(497, 8)
    20 -> #(753, 9)
    21 -> #(1265, 10)
    22 -> #(2289, 11)
    23 -> #(4337, 12)
    24 -> #(8433, 13)
    _ -> #(16_625, 24)
  }
}

/// Decrement the block-length counter; if it hits zero and the block
/// has more than one type, read a block-switch (new type + length).
fn maybe_switch_block(
  reader: Reader,
  block: BlockState,
) -> Result(#(BlockState, Reader), error.CodecError) {
  case block.length > 1 {
    True -> Ok(#(BlockState(..block, length: block.length - 1), reader))
    False -> {
      case block.type_code, block.length_code {
        Some(type_code), Some(length_code) ->
          perform_block_switch(reader, block, type_code, length_code)
        _, _ -> Ok(#(BlockState(..block, length: block.length - 1), reader))
      }
    }
  }
}

fn perform_block_switch(
  reader: Reader,
  block: BlockState,
  type_code: PrefixCode,
  length_code: PrefixCode,
) -> Result(#(BlockState, Reader), error.CodecError) {
  use #(type_symbol, reader) <- result.try(decode_prefix_symbol(
    reader,
    type_code,
  ))
  let new_type = resolve_block_type(type_symbol, block)
  use #(length, reader) <- result.try(read_block_length(reader, length_code))
  Ok(#(
    BlockState(
      ..block,
      type_: new_type,
      length: length,
      rb_prev: block.rb_curr,
      rb_curr: new_type,
    ),
    reader,
  ))
}

fn resolve_block_type(symbol: Int, block: BlockState) -> Int {
  let raw = case symbol {
    0 -> block.rb_prev
    1 -> int.bitwise_and(block.rb_curr + 1, 0x7FFF_FFFF)
    n -> n - 2
  }
  case raw >= block.nbltypes {
    True -> raw - block.nbltypes
    False -> raw
  }
}

/// Decode a context map per RFC 7932 §7.3.  When `ntrees == 1` the
/// map is implicitly all zeros and no bits are read.  Otherwise:
///
/// 1. Read 1 bit.  If 1, read 4 more bits to compute `RLEMAX = bits + 1`
///    (range 1..16).  If 0, `RLEMAX = 0`.
/// 2. Read a prefix code for the alphabet of size `ntrees + RLEMAX`.
/// 3. Decode `size` entries:
///    * `code == 0` → emit a 0
///    * `code > RLEMAX` → emit `code - RLEMAX`
///    * `1 <= code <= RLEMAX` → read `code` extra bits; reps
///      = extra + (1 << code); emit that many zeros
/// 4. Read 1 bit.  If 1, apply inverse-move-to-front transform.
fn decode_context_map(
  reader: Reader,
  ntrees: Int,
  size: Int,
) -> Result(#(BitArray, Reader), error.CodecError) {
  case ntrees <= 1 {
    True -> Ok(#(byte_repeat(0, size), reader))
    False -> decode_nontrivial_context_map(reader, ntrees, size)
  }
}

fn decode_nontrivial_context_map(
  reader: Reader,
  ntrees: Int,
  size: Int,
) -> Result(#(BitArray, Reader), error.CodecError) {
  use #(use_rle, reader) <- result.try(read_bits(reader, 1))
  use #(rlemax, reader) <- result.try(case use_rle {
    0 -> Ok(#(0, reader))
    _ -> {
      use #(extra, reader) <- result.try(read_bits(reader, 4))
      Ok(#(extra + 1, reader))
    }
  })
  let alphabet_size = ntrees + rlemax
  use #(code, reader) <- result.try(decode_prefix_code(
    reader,
    alphabet_size,
    "context-map",
  ))
  use #(entries, reader) <- result.try(
    decode_context_map_entries(reader, code, rlemax, size, []),
  )
  use #(imtf_flag, reader) <- result.try(read_bits(reader, 1))
  let entries = case imtf_flag {
    0 -> entries
    _ -> imtf(entries)
  }
  Ok(#(bytes_from_int_list(entries), reader))
}

fn decode_context_map_entries(
  reader: Reader,
  code: PrefixCode,
  rlemax: Int,
  remaining: Int,
  acc: List(Int),
) -> Result(#(List(Int), Reader), error.CodecError) {
  case remaining {
    n if n <= 0 -> Ok(#(list.reverse(acc), reader))
    _ -> step_context_map_entry(reader, code, rlemax, remaining, acc)
  }
}

fn step_context_map_entry(
  reader: Reader,
  code: PrefixCode,
  rlemax: Int,
  remaining: Int,
  acc: List(Int),
) -> Result(#(List(Int), Reader), error.CodecError) {
  use #(symbol, reader) <- result.try(decode_prefix_symbol(reader, code))
  case symbol == 0 || symbol > rlemax {
    True -> {
      let value = symbol_to_value(symbol, rlemax)
      decode_context_map_entries(reader, code, rlemax, remaining - 1, [
        value,
        ..acc
      ])
    }
    False -> {
      // 1 ≤ symbol ≤ rlemax: zero-run.
      use #(extra, reader) <- result.try(read_bits(reader, symbol))
      let reps = extra + int.bitwise_shift_left(1, symbol)
      use <- bool.guard(
        when: reps > remaining,
        return: Error(error.CodecInvalidData(
          message: "brotli context-map zero run overruns map size",
        )),
      )
      decode_context_map_entries(
        reader,
        code,
        rlemax,
        remaining - reps,
        prepend_zeros(reps, acc),
      )
    }
  }
}

fn symbol_to_value(symbol: Int, rlemax: Int) -> Int {
  case symbol {
    0 -> 0
    _ -> symbol - rlemax
  }
}

fn prepend_zeros(n: Int, acc: List(Int)) -> List(Int) {
  case n {
    0 -> acc
    _ -> prepend_zeros(n - 1, [0, ..acc])
  }
}

fn bytes_from_int_list(values: List(Int)) -> BitArray {
  list.fold(values, <<>>, fn(acc, v) { <<acc:bits, v>> })
}

fn byte_repeat(byte: Int, count: Int) -> BitArray {
  byte_repeat_loop(byte, count, <<>>)
}

fn byte_repeat_loop(byte: Int, count: Int, acc: BitArray) -> BitArray {
  case count {
    n if n <= 0 -> acc
    _ -> byte_repeat_loop(byte, count - 1, <<acc:bits, byte>>)
  }
}

// -- Inverse Move-to-Front transform (RFC 7932 §7.3) -------------------

/// Apply IMTF to a list of byte indices.  Initial table is [0..255].
/// For each index `i`: emit `table[i]`, then move that value to the
/// front (shifting earlier entries one place back).
fn imtf(input: List(Int)) -> List(Int) {
  imtf_loop(input, init_mtf(255, []), [])
}

fn init_mtf(n: Int, acc: List(Int)) -> List(Int) {
  case n < 0 {
    True -> acc
    False -> init_mtf(n - 1, [n, ..acc])
  }
}

fn imtf_loop(
  input: List(Int),
  table: List(Int),
  output: List(Int),
) -> List(Int) {
  case input {
    [] -> list.reverse(output)
    [idx, ..rest] -> {
      let value = mtf_value_at(table, idx)
      let new_table = [value, ..list.filter(table, fn(v) { v != value })]
      imtf_loop(rest, new_table, [value, ..output])
    }
  }
}

fn mtf_value_at(table: List(Int), idx: Int) -> Int {
  case table, idx {
    [head, ..], 0 -> head
    [_, ..tail], _ -> mtf_value_at(tail, idx - 1)
    [], _ -> 0
  }
}

// -- Prefix code descriptors (RFC 7932 §3.4) ---------------------------

/// A decoded prefix code: each entry pairs a symbol with its canonical
/// MSB-first code value and bit length.  A length of 0 marks the
/// degenerate one-symbol code that consumes no bits.
type PrefixCode {
  PrefixCode(entries: List(PrefixEntry))
}

type PrefixEntry {
  PrefixEntry(symbol: Int, length: Int, code: Int)
}

fn decode_prefix_codes(
  reader: Reader,
  remaining: Int,
  alphabet_size: Int,
  kind: String,
  acc: List(PrefixCode),
) -> Result(#(List(PrefixCode), Reader), error.CodecError) {
  case remaining {
    0 -> Ok(#(list.reverse(acc), reader))
    _ -> {
      use #(code, reader) <- result.try(decode_prefix_code(
        reader,
        alphabet_size,
        kind,
      ))
      decode_prefix_codes(reader, remaining - 1, alphabet_size, kind, [
        code,
        ..acc
      ])
    }
  }
}

fn decode_prefix_code(
  reader: Reader,
  alphabet_size: Int,
  _kind: String,
) -> Result(#(PrefixCode, Reader), error.CodecError) {
  use #(descriptor, reader) <- result.try(read_bits(reader, 2))
  case descriptor {
    1 -> decode_simple_prefix_code(reader, alphabet_size)
    // 0, 2, 3 → complex form (HSKIP = descriptor, RFC 7932 §3.5).
    hskip -> decode_complex_prefix_code(reader, alphabet_size, hskip)
  }
}

fn decode_simple_prefix_code(
  reader: Reader,
  alphabet_size: Int,
) -> Result(#(PrefixCode, Reader), error.CodecError) {
  use #(nsym_minus_1, reader) <- result.try(read_bits(reader, 2))
  let nsym = nsym_minus_1 + 1
  let alphabet_bits = ceil_log2(alphabet_size)
  use #(symbols, reader) <- result.try(
    read_simple_symbols(reader, nsym, alphabet_bits, []),
  )
  use _ <- result.try(check_alphabet_bounds(symbols, alphabet_size))
  use _ <- result.try(check_no_duplicates(symbols))
  build_simple_layout(reader, nsym, symbols)
}

fn build_simple_layout(
  reader: Reader,
  nsym: Int,
  symbols: List(Int),
) -> Result(#(PrefixCode, Reader), error.CodecError) {
  case nsym {
    1 -> Ok(#(canonicalise(symbols, [0]), reader))
    2 -> Ok(#(canonicalise(sort_asc(symbols), [1, 1]), reader))
    3 -> {
      // RFC 7932 §3.4: the first symbol keeps its position and gets a
      // length-1 code; the remaining two are sorted ascending and get
      // length-2 codes.
      let assert [first, ..rest] = symbols
      let sorted_rest = sort_asc(rest)
      Ok(#(canonicalise([first, ..sorted_rest], [1, 2, 2]), reader))
    }
    _ -> {
      use #(tree_select, reader) <- result.try(read_bits(reader, 1))
      case tree_select {
        0 -> Ok(#(canonicalise(sort_asc(symbols), [2, 2, 2, 2]), reader))
        _ -> {
          let assert [first, ..rest] = symbols
          let sorted_rest = sort_asc(rest)
          Ok(#(canonicalise([first, ..sorted_rest], [1, 2, 3, 3]), reader))
        }
      }
    }
  }
}

/// Build a canonical-Huffman `PrefixCode` from a parallel list of
/// symbols and code-lengths.  Walks `(symbol, length)` pairs in
/// length-ascending order, assigning MSB-first code values via the
/// standard canonical-Huffman recurrence.
fn canonicalise(symbols: List(Int), lengths: List(Int)) -> PrefixCode {
  let pairs = list.zip(symbols, lengths)
  let sorted =
    list.sort(pairs, fn(a, b) {
      let #(_, len_a) = a
      let #(_, len_b) = b
      int.compare(len_a, len_b)
    })
  PrefixCode(entries: assign_canonical(sorted, 0, 0, []))
}

fn assign_canonical(
  pairs: List(#(Int, Int)),
  next_code: Int,
  prev_length: Int,
  acc: List(PrefixEntry),
) -> List(PrefixEntry) {
  case pairs {
    [] -> list.reverse(acc)
    [#(sym, len), ..rest] -> {
      let shifted = int.bitwise_shift_left(next_code, len - prev_length)
      assign_canonical(rest, shifted + 1, len, [
        PrefixEntry(symbol: sym, length: len, code: shifted),
        ..acc
      ])
    }
  }
}

/// Build a `PrefixCode` from `(symbol, length)` pairs where a length
/// of 0 indicates the symbol is absent from the code.  Sorts the
/// remaining pairs by `(length asc, symbol asc)` and applies the
/// canonical-Huffman recurrence.  Collapses the degenerate single-
/// active-symbol case to length 0 to match RFC 7932 §3.5.
fn canonicalise_from_pairs(pairs: List(#(Int, Int))) -> PrefixCode {
  let active =
    list.filter(pairs, fn(p) {
      let #(_, len) = p
      len > 0
    })
  case active {
    [#(sym, _)] ->
      PrefixCode(entries: [PrefixEntry(symbol: sym, length: 0, code: 0)])
    _ -> {
      let by_sym =
        list.sort(active, fn(a, b) {
          let #(sa, _) = a
          let #(sb, _) = b
          int.compare(sa, sb)
        })
      let by_len =
        list.sort(by_sym, fn(a, b) {
          let #(_, la) = a
          let #(_, lb) = b
          int.compare(la, lb)
        })
      PrefixCode(entries: assign_canonical(by_len, 0, 0, []))
    }
  }
}

// -- Complex-form prefix codes (RFC 7932 §3.5) -------------------------
//
// The encoding is two-stage: first the lengths of an 18-symbol code
// (covering literal code lengths 0..15 plus repeat-prev=16 and
// repeat-zero=17) are read using a fixed 16-entry lookup table; then
// those lengths build a Huffman "CL" code which itself decodes the
// final alphabet's code lengths, with the 16/17 repeats expanding
// runs of the previous (non-zero or zero) length.

/// Read order for the 18 code-length-code-lengths.  HSKIP entries are
/// implicitly zero; the remainder is read in this order until either
/// all are consumed or the Huffman space (32) is exhausted.
fn cl_code_order() -> List(Int) {
  [1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15]
}

/// Lookup tables for the fixed 4-bit code that encodes each CL
/// code-length value.  Indexed by a 4-bit peek; returns
/// `#(bits_to_consume, value)`.  Values are in 0..5 — never 6..15 —
/// since CL code-lengths can't exceed 5 bits.  Mirrors the brotli C
/// reference `kCodeLengthPrefixLength` + `kCodeLengthPrefixValue`.
fn cl_prefix_lookup(ix: Int) -> #(Int, Int) {
  case ix {
    0 -> #(2, 0)
    1 -> #(2, 4)
    2 -> #(2, 3)
    3 -> #(3, 2)
    4 -> #(2, 0)
    5 -> #(2, 4)
    6 -> #(2, 3)
    7 -> #(4, 1)
    8 -> #(2, 0)
    9 -> #(2, 4)
    10 -> #(2, 3)
    11 -> #(3, 2)
    12 -> #(2, 0)
    13 -> #(2, 4)
    14 -> #(2, 3)
    _ -> #(4, 5)
  }
}

fn decode_complex_prefix_code(
  reader: Reader,
  alphabet_size: Int,
  hskip: Int,
) -> Result(#(PrefixCode, Reader), error.CodecError) {
  let order = list.drop(cl_code_order(), hskip)
  use #(cl_pairs, reader) <- result.try(
    read_cl_code_lengths(reader, order, 32, 0, []),
  )
  let cl_code = canonicalise_from_pairs(cl_pairs)
  use #(symbol_pairs, reader) <- result.try(
    read_symbol_code_lengths(
      reader,
      cl_code,
      alphabet_size,
      SymLenState(symbol: 0, space: 32_768, prev: 8, repeat: 0, repeat_len: 0),
      [],
    ),
  )
  Ok(#(canonicalise_from_pairs(symbol_pairs), reader))
}

fn read_cl_code_lengths(
  reader: Reader,
  remaining_order: List(Int),
  space: Int,
  num_codes: Int,
  accum: List(#(Int, Int)),
) -> Result(#(List(#(Int, Int)), Reader), error.CodecError) {
  case remaining_order {
    [] -> validate_cl_space(num_codes, space, accum, reader)
    [cl_sym, ..rest] ->
      read_one_cl(reader, cl_sym, rest, space, num_codes, accum)
  }
}

fn read_one_cl(
  reader: Reader,
  cl_sym: Int,
  rest: List(Int),
  space: Int,
  num_codes: Int,
  accum: List(#(Int, Int)),
) -> Result(#(List(#(Int, Int)), Reader), error.CodecError) {
  use reader <- result.try(ensure_bits(reader, 4))
  let ix = peek_bits_value(reader, 4)
  let #(consume, value) = cl_prefix_lookup(ix)
  let reader = drop_bits(reader, consume)
  let new_accum = [#(cl_sym, value), ..accum]
  case value {
    0 -> read_cl_code_lengths(reader, rest, space, num_codes, new_accum)
    _ -> {
      let new_space = space - int.bitwise_shift_right(32, value)
      let new_num = num_codes + 1
      case new_space <= 0 {
        True -> validate_cl_space(new_num, new_space, new_accum, reader)
        False ->
          read_cl_code_lengths(reader, rest, new_space, new_num, new_accum)
      }
    }
  }
}

fn validate_cl_space(
  num_codes: Int,
  space: Int,
  accum: List(#(Int, Int)),
  reader: Reader,
) -> Result(#(List(#(Int, Int)), Reader), error.CodecError) {
  use <- bool.guard(
    when: space < 0,
    return: Error(error.CodecInvalidData(
      message: "brotli code-length codes oversubscribe Huffman space",
    )),
  )
  case num_codes == 1 || space == 0 {
    True -> {
      Ok(#(accum, reader))
    }
    False ->
      Error(error.CodecInvalidData(
        message: "brotli code-length codes underfill Huffman space",
      ))
  }
}

type SymLenState {
  SymLenState(symbol: Int, space: Int, prev: Int, repeat: Int, repeat_len: Int)
}

fn read_symbol_code_lengths(
  reader: Reader,
  cl_code: PrefixCode,
  alphabet_size: Int,
  state: SymLenState,
  accum: List(#(Int, Int)),
) -> Result(#(List(#(Int, Int)), Reader), error.CodecError) {
  case state.symbol >= alphabet_size || state.space <= 0 {
    True -> finalize_symbol_lengths(reader, state, accum)
    False -> step_symbol_length(reader, cl_code, alphabet_size, state, accum)
  }
}

fn finalize_symbol_lengths(
  reader: Reader,
  state: SymLenState,
  accum: List(#(Int, Int)),
) -> Result(#(List(#(Int, Int)), Reader), error.CodecError) {
  use <- bool.guard(
    when: state.space != 0,
    return: Error(error.CodecInvalidData(
      message: "brotli symbol code lengths do not fully consume Huffman space",
    )),
  )
  Ok(#(accum, reader))
}

fn step_symbol_length(
  reader: Reader,
  cl_code: PrefixCode,
  alphabet_size: Int,
  state: SymLenState,
  accum: List(#(Int, Int)),
) -> Result(#(List(#(Int, Int)), Reader), error.CodecError) {
  use #(code_len, reader) <- result.try(decode_prefix_symbol(reader, cl_code))
  case code_len < 16 {
    True ->
      apply_single_code_length(
        reader,
        cl_code,
        alphabet_size,
        state,
        accum,
        code_len,
      )
    False ->
      apply_repeat_code_length(
        reader,
        cl_code,
        alphabet_size,
        state,
        accum,
        code_len,
      )
  }
}

fn apply_single_code_length(
  reader: Reader,
  cl_code: PrefixCode,
  alphabet_size: Int,
  state: SymLenState,
  accum: List(#(Int, Int)),
  code_len: Int,
) -> Result(#(List(#(Int, Int)), Reader), error.CodecError) {
  let new_accum = case code_len {
    0 -> accum
    _ -> [#(state.symbol, code_len), ..accum]
  }
  let new_space = case code_len {
    0 -> state.space
    _ -> state.space - int.bitwise_shift_right(32_768, code_len)
  }
  let new_prev = case code_len {
    0 -> state.prev
    _ -> code_len
  }
  let new_state =
    SymLenState(
      symbol: state.symbol + 1,
      space: new_space,
      prev: new_prev,
      repeat: 0,
      repeat_len: 0,
    )
  read_symbol_code_lengths(reader, cl_code, alphabet_size, new_state, new_accum)
}

fn apply_repeat_code_length(
  reader: Reader,
  cl_code: PrefixCode,
  alphabet_size: Int,
  state: SymLenState,
  accum: List(#(Int, Int)),
  code_len: Int,
) -> Result(#(List(#(Int, Int)), Reader), error.CodecError) {
  let #(new_len, extra_bits) = case code_len {
    16 -> #(state.prev, 2)
    _ -> #(0, 3)
  }
  use #(extra, reader) <- result.try(read_bits(reader, extra_bits))
  let prior_repeat = case state.repeat_len == new_len {
    True -> state.repeat
    False -> 0
  }
  let scaled = case prior_repeat > 0 {
    True -> int.bitwise_shift_left(prior_repeat - 2, extra_bits)
    False -> 0
  }
  let new_repeat = scaled + extra + 3
  let delta = new_repeat - prior_repeat
  use <- bool.guard(
    when: state.symbol + delta > alphabet_size,
    return: Error(error.CodecInvalidData(
      message: "brotli repeat code overruns alphabet",
    )),
  )
  let #(new_accum, new_space) = case new_len {
    0 -> #(accum, state.space)
    _ -> #(
      prepend_repeated(state.symbol, delta, new_len, accum),
      state.space - int.bitwise_shift_left(delta, 15 - new_len),
    )
  }
  let new_state =
    SymLenState(
      symbol: state.symbol + delta,
      space: new_space,
      prev: state.prev,
      repeat: new_repeat,
      repeat_len: new_len,
    )
  read_symbol_code_lengths(reader, cl_code, alphabet_size, new_state, new_accum)
}

fn prepend_repeated(
  start: Int,
  delta: Int,
  length: Int,
  acc: List(#(Int, Int)),
) -> List(#(Int, Int)) {
  case delta {
    0 -> acc
    _ ->
      prepend_repeated(start + 1, delta - 1, length, [#(start, length), ..acc])
  }
}

fn decode_prefix_symbol(
  reader: Reader,
  code: PrefixCode,
) -> Result(#(Int, Reader), error.CodecError) {
  decode_prefix_walk(reader, code.entries, 0, 0)
}

fn decode_prefix_walk(
  reader: Reader,
  entries: List(PrefixEntry),
  accumulated: Int,
  bit_count: Int,
) -> Result(#(Int, Reader), error.CodecError) {
  // `use <- result.try(...)` breaks TCO on the JS target — inline the
  // case match so the recursive call stays in tail position.  Without
  // this, a compressed metablock with thousands of literal symbols
  // accumulates one stack frame per `read_bits` call and blows past
  // the JS engine's ~10 000-frame limit.
  case find_prefix_entry(entries, bit_count, accumulated) {
    Ok(symbol) -> Ok(#(symbol, reader))
    Error(_) ->
      case read_bits(reader, 1) {
        Error(e) -> Error(e)
        Ok(#(bit, reader)) -> {
          let new_acc = int.bitwise_shift_left(accumulated, 1) + bit
          decode_prefix_walk(reader, entries, new_acc, bit_count + 1)
        }
      }
  }
}

fn find_prefix_entry(
  entries: List(PrefixEntry),
  length: Int,
  value: Int,
) -> Result(Int, Nil) {
  case entries {
    [] -> Error(Nil)
    [entry, ..rest] ->
      case entry.length == length && entry.code == value {
        True -> Ok(entry.symbol)
        False -> find_prefix_entry(rest, length, value)
      }
  }
}

fn ceil_log2(n: Int) -> Int {
  ceil_log2_loop(n, 0, 1)
}

fn ceil_log2_loop(target: Int, k: Int, pow: Int) -> Int {
  case pow >= target {
    True -> k
    False -> ceil_log2_loop(target, k + 1, pow * 2)
  }
}

fn read_simple_symbols(
  reader: Reader,
  remaining: Int,
  bits_per: Int,
  acc: List(Int),
) -> Result(#(List(Int), Reader), error.CodecError) {
  case remaining {
    0 -> Ok(#(list.reverse(acc), reader))
    _ -> {
      use #(sym, reader) <- result.try(read_bits(reader, bits_per))
      read_simple_symbols(reader, remaining - 1, bits_per, [sym, ..acc])
    }
  }
}

fn sort_asc(symbols: List(Int)) -> List(Int) {
  list.sort(symbols, int.compare)
}

fn check_no_duplicates(symbols: List(Int)) -> Result(Nil, error.CodecError) {
  case has_consecutive_dup(sort_asc(symbols)) {
    True ->
      Error(error.CodecInvalidData(
        message: "brotli simple-form prefix code has duplicate symbols",
      ))
    False -> Ok(Nil)
  }
}

fn has_consecutive_dup(sorted: List(Int)) -> Bool {
  case sorted {
    [] -> False
    [_] -> False
    [a, b, ..] if a == b -> True
    [_, ..rest] -> has_consecutive_dup(rest)
  }
}

fn check_alphabet_bounds(
  symbols: List(Int),
  alphabet_size: Int,
) -> Result(Nil, error.CodecError) {
  case list.any(symbols, fn(s) { s >= alphabet_size }) {
    True ->
      Error(error.CodecInvalidData(
        message: "brotli simple-form prefix code symbol exceeds alphabet size",
      ))
    False -> Ok(Nil)
  }
}

fn read_context_modes(
  reader: Reader,
  remaining: Int,
  acc: List(Int),
) -> Result(#(List(Int), Reader), error.CodecError) {
  case remaining {
    0 -> Ok(#(list.reverse(acc), reader))
    _ -> {
      use #(mode, reader) <- result.try(read_bits(reader, 2))
      read_context_modes(reader, remaining - 1, [mode, ..acc])
    }
  }
}

// -- RFC 7932 §9.2 variable-length 8-bit integer -----------------------
//
// Encodes a number in 0..255 using 1–11 bits.  Used for NBLTYPES,
// NTREES, and other small population counts.
fn decode_var_len_uint8(
  reader: Reader,
) -> Result(#(Int, Reader), error.CodecError) {
  use #(first, reader) <- result.try(read_bits(reader, 1))
  case first {
    0 -> Ok(#(1, reader))
    _ -> {
      use #(triple, reader) <- result.try(read_bits(reader, 3))
      case triple {
        0 -> Ok(#(2, reader))
        n -> {
          use #(extra, reader) <- result.try(read_bits(reader, n))
          let base = int.bitwise_shift_left(1, n)
          Ok(#(base + extra + 1, reader))
        }
      }
    }
  }
}

fn decode_skip_metablock(
  reader: Reader,
  output: BitArray,
  ring: DistRing,
) -> Result(#(BitArray, DistRing, Reader), error.CodecError) {
  use #(reserved, reader) <- result.try(read_bits(reader, 1))
  use <- bool.guard(
    when: reserved != 0,
    return: Error(error.CodecInvalidData(
      message: "brotli skip metablock reserved bit must be zero",
    )),
  )
  use #(mskipbytes, reader) <- result.try(read_bits(reader, 2))
  use #(mskiplen, reader) <- result.try(case mskipbytes {
    0 -> Ok(#(0, reader))
    n -> read_bits(reader, n * 8)
  })
  let skip = mskiplen + 1
  let reader = align_to_byte(reader)
  let reader = consume_bytes(reader, skip)
  Ok(#(output, ring, reader))
}

fn decode_uncompressed_metablock(
  reader: Reader,
  output: BitArray,
  ring: DistRing,
  mlen: Int,
  limits: limit.Limits,
) -> Result(#(BitArray, DistRing, Reader), error.CodecError) {
  let reader = align_to_byte(reader)
  use #(chunk, reader) <- result.try(take_bytes(reader, mlen))
  let projected = bit_array.byte_size(output) + bit_array.byte_size(chunk)
  case projected > limit.max_output_bytes(limits) {
    True ->
      Error(error.CodecLimitExceeded(
        limit: "max_output_bytes",
        actual: projected,
      ))
    False -> Ok(#(bit_array.concat([output, chunk]), ring, reader))
  }
}

// -- WBITS prefix ------------------------------------------------------

/// Read the WBITS prefix per RFC 7932 §9.1.  The encoding is:
///
/// * `0` → 16
/// * `1nnn` where `nnn ≠ 000` → 17 + nnn (range 18..24)
/// * `1000 nnn` where `nnn ≠ 000` and `nnn ≠ 001` → 8 + nnn (range 10..15)
/// * `1000 000` → 17
/// * `1000 001` → reserved / large-window indicator (not supported)
fn read_wbits(reader: Reader) -> Result(#(Int, Reader), error.CodecError) {
  use #(first, reader) <- result.try(read_bits(reader, 1))
  case first {
    0 -> Ok(#(16, reader))
    _ -> read_wbits_after_lead(reader)
  }
}

fn read_wbits_after_lead(
  reader: Reader,
) -> Result(#(Int, Reader), error.CodecError) {
  use #(triple, reader) <- result.try(read_bits(reader, 3))
  case triple {
    0 -> read_wbits_short_range(reader)
    n -> Ok(#(17 + n, reader))
  }
}

fn read_wbits_short_range(
  reader: Reader,
) -> Result(#(Int, Reader), error.CodecError) {
  use #(extra, reader) <- result.try(read_bits(reader, 3))
  case extra {
    0 -> Ok(#(17, reader))
    1 ->
      Error(error.CodecInvalidData(
        message: "brotli large-window WBITS prefix is not supported",
      ))
    n -> Ok(#(8 + n, reader))
  }
}

// -- LSB-first bit reader (with byte-aligned tail access) ---------------

type Reader {
  Reader(source: BitArray, buffer: Int, bits: Int, overflow: Bool)
}

fn new_reader(source: BitArray) -> Reader {
  Reader(source: source, buffer: 0, bits: 0, overflow: False)
}

fn refill(reader: Reader, needed: Int) -> Reader {
  case reader.bits >= needed || reader.overflow {
    True -> reader
    False ->
      case reader.source {
        <<b, rest:bytes>> ->
          refill(
            Reader(
              source: rest,
              buffer: int.bitwise_or(
                reader.buffer,
                int.bitwise_shift_left(b, reader.bits),
              ),
              bits: reader.bits + 8,
              overflow: False,
            ),
            needed,
          )
        _ ->
          Reader(
            source: <<>>,
            buffer: reader.buffer,
            bits: reader.bits,
            overflow: True,
          )
      }
  }
}

fn read_bits(
  reader: Reader,
  count: Int,
) -> Result(#(Int, Reader), error.CodecError) {
  case count {
    0 -> Ok(#(0, reader))
    _ -> {
      use reader <- result.try(ensure_bits(reader, count))
      let value = peek_bits_value(reader, count)
      Ok(#(value, drop_bits(reader, count)))
    }
  }
}

/// Refill the bit buffer until it holds at least `count` bits; error
/// out if the source stream is shorter than that.  Used by both
/// `read_bits` and the peek/drop API the complex-form prefix code
/// reader needs (to look up a variable-length CL code by 4-bit peek).
fn ensure_bits(reader: Reader, count: Int) -> Result(Reader, error.CodecError) {
  let reader = refill(reader, count)
  case reader.bits >= count {
    True -> Ok(reader)
    False ->
      Error(error.CodecInvalidData(message: "truncated brotli bit stream"))
  }
}

/// LSB-first read of `count` bits without consuming them.  Callers
/// must first call `ensure_bits` to guarantee the buffer is filled.
fn peek_bits_value(reader: Reader, count: Int) -> Int {
  let mask = int.bitwise_shift_left(1, count) - 1
  int.bitwise_and(reader.buffer, mask)
}

/// Consume `count` bits previously inspected with `peek_bits_value`.
fn drop_bits(reader: Reader, count: Int) -> Reader {
  Reader(
    source: reader.source,
    buffer: int.bitwise_shift_right(reader.buffer, count),
    bits: reader.bits - count,
    overflow: reader.overflow,
  )
}

/// Drop the remaining bits in the current byte so the next byte-level
/// operation aligns to a byte boundary.  This matches brotli's
/// `jump_to_byte_boundary` step before an uncompressed-metablock copy
/// or a skip-metablock skip.
fn align_to_byte(reader: Reader) -> Reader {
  let leftover = reader.bits % 8
  case leftover {
    0 -> reader
    _ -> {
      let value = int.bitwise_shift_right(reader.buffer, leftover)
      let bits = reader.bits - leftover
      Reader(
        source: reader.source,
        buffer: value,
        bits: bits,
        overflow: reader.overflow,
      )
    }
  }
}

fn take_bytes(
  reader: Reader,
  count: Int,
) -> Result(#(BitArray, Reader), error.CodecError) {
  // After align_to_byte, reader.bits is a multiple of 8.  Pull entire
  // bytes from the buffer first, then from source.
  let buffered_bytes = reader.bits / 8
  case count <= buffered_bytes {
    True -> {
      let chunk = bits_to_bit_array(reader.buffer, count, <<>>)
      let remaining_bits = reader.bits - count * 8
      let mask = int.bitwise_shift_left(1, remaining_bits) - 1
      let new_buffer =
        int.bitwise_and(int.bitwise_shift_right(reader.buffer, count * 8), mask)
      Ok(#(
        chunk,
        Reader(
          source: reader.source,
          buffer: new_buffer,
          bits: remaining_bits,
          overflow: reader.overflow,
        ),
      ))
    }
    False -> {
      let buffer_chunk = bits_to_bit_array(reader.buffer, buffered_bytes, <<>>)
      let need = count - buffered_bytes
      case bit_array.slice(reader.source, 0, need) {
        Ok(source_chunk) -> {
          let assert Ok(new_source) =
            bit_array.slice(
              reader.source,
              need,
              bit_array.byte_size(reader.source) - need,
            )
          Ok(#(
            bit_array.concat([buffer_chunk, source_chunk]),
            Reader(source: new_source, buffer: 0, bits: 0, overflow: False),
          ))
        }
        Error(_) ->
          Error(error.CodecInvalidData(
            message: "brotli uncompressed metablock body is truncated",
          ))
      }
    }
  }
}

fn consume_bytes(reader: Reader, count: Int) -> Reader {
  case take_bytes(reader, count) {
    Ok(#(_, r)) -> r
    Error(_) -> reader
  }
}

fn bits_to_bit_array(buffer: Int, count: Int, acc: BitArray) -> BitArray {
  case count {
    0 -> acc
    _ ->
      bits_to_bit_array(int.bitwise_shift_right(buffer, 8), count - 1, <<
        acc:bits,
        int.bitwise_and(buffer, 0xFF),
      >>)
  }
}
