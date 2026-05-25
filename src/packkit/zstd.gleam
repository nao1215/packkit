//// Zstandard codec — pure-Gleam decoder.
////
//// The module parses the Zstandard frame envelope (magic, frame
//// header descriptor, window descriptor, optional dictionary id,
//// optional frame content size, optional trailing content checksum)
//// and walks the block stream.  Raw and RLE blocks decode directly;
//// compressed blocks (type 2) decode through the FSE tables in
//// `packkit/internal/fse`.  Sequences with `Predefined_Mode`,
//// `RLE_Mode`, and `FSE_Compressed_Mode` symbol descriptions all
//// decode (LL, OF, ML independently).  All four literal block
//// types decode: `Raw_Literals_Block`, `RLE_Literals_Block`,
//// `Compressed_Literals_Block` (Huffman-coded with direct-weight
//// or FSE-weight tree descriptions, 1-stream or 4-stream form),
//// and `Treeless_Literals_Block` (which reuses the prior block's
//// Huffman tree via the cross-block tree state threaded through
//// the block loop).  A treeless block in the first position of a
//// frame surfaces as a typed `CodecInvalidData`.  `Repeat_Mode`
//// for sequence-symbol descriptions also threads its FSE tables
//// across blocks (per RFC 8478 §3.1.1.4 the LL / OF / ML tables
//// survive across blocks within a frame), and a Repeat_Mode in the
//// first block of a frame surfaces as a typed `CodecInvalidData`.

import gleam/bit_array
import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import packkit/codec as codecs
import packkit/error
import packkit/internal/fse
import packkit/internal/huf
import packkit/limit

const magic: Int = 0xFD2FB528

/// Zstandard codec smart constructor.
pub fn codec() -> codecs.Codec {
  codecs.zstd()
}

// Upper bound for any single block this encoder emits.  16 KiB - 1
// is the largest `regenerated_size` and `compressed_size` the
// size_format = 2 literals header (4 streams, 14-bit fields) can
// carry, and keeping all chunks under that one cap lets every block
// pick its own representation independently — Raw, RLE, 1-stream
// Huffman (small chunks), or 4-stream Huffman (larger chunks).
const max_block_chunk: Int = 16_383

// Single-stream Huffman literals header (`size_format = 0`) caps
// regenerated_size at 10 bits = 1023 bytes.  Above that we switch to
// the 4-stream form (`size_format = 2`, 14-bit fields).
const huffman_1stream_max_regen: Int = 1023

const huffman_max_block_compressed: Int = 1024

// 4-stream form's compressed_size limit (14 bits = 16383).  The +6
// jump table and shared Huffman tree count toward it.
const huffman_4stream_max_compressed: Int = 16_383

const huffman_max_tree_depth: Int = 11

// Skip the Huffman path for very small chunks: the ~129-byte tree
// description never amortises below a few hundred input bytes.
const huffman_min_input_size: Int = 64

/// Encode `bytes` as a Zstandard frame.  The encoder picks the
/// cheapest of `Raw_Block` and `RLE_Block` per chunk — a chunk that
/// repeats a single byte collapses to a 1-byte RLE payload — so
/// inputs like `repeat('A', N)` compress, but mixed input still
/// passes through as raw bytes.  No LZ77 or Huffman compression yet,
/// no content checksum.  Output is a valid Zstandard frame any
/// conforming decoder can read.
pub fn encode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  let size = bit_array.byte_size(bytes)
  use header <- result.try(frame_header_for_size(size))
  let blocks = build_raw_blocks(bytes, size)
  Ok(bit_array.concat([header, blocks]))
}

/// Build the Zstandard frame header for a payload of `size` bytes.
/// Exposed for tests that need to assert on the FCS layout for sizes
/// too large to materialise in memory (e.g. 4 GiB+ frames where the
/// header used to silently truncate the FCS field to its low 32 bits).
pub fn frame_header_for_size(size: Int) -> Result(BitArray, error.CodecError) {
  // Single_Segment_flag = 1, no Window_Descriptor, no Dictionary_ID,
  // no Content_Checksum.  FCS encoding follows the size — 1 byte for
  // < 256, 2 bytes (FCS_flag = 1) for the 256..65535 range, 4 bytes
  // (FCS_flag = 2) for the 65536..(2^32)-1 range, otherwise 8 bytes
  // (FCS_flag = 3).
  case size {
    n if n < 256 -> Ok(<<0x28, 0xB5, 0x2F, 0xFD, 0x20, n>>)
    n if n < 0x1_0000 ->
      Ok(<<
        0x28,
        0xB5,
        0x2F,
        0xFD,
        0x60,
        { n - 256 }:size(16)-little,
      >>)
    n if n < 0x1_0000_0000 ->
      Ok(<<
        0x28,
        0xB5,
        0x2F,
        0xFD,
        0xA0,
        n:size(32)-little,
      >>)
    n -> {
      // FCS_flag = 3: full unsigned 64-bit little-endian field.
      // The previous encoder packed `n` into the low 32 bits and a
      // literal `0` into the high 32 bits, silently truncating any
      // payload at or above 4 GiB to `n mod 2^32` bytes.  The 2^64
      // ceiling is enforced by checking the high half rather than via
      // a literal upper bound, because 0xFFFFFFFFFFFFFFFF would warn
      // as outside JavaScript's safe-integer range on that target.
      let lo = int.bitwise_and(n, 0xFFFFFFFF)
      let high_half = int.bitwise_shift_right(n, 32)
      use <- bool.guard(
        when: high_half > 0xFFFFFFFF,
        return: Error(error.CodecLimitExceeded(
          limit: "zstd frame_content_size",
          actual: n,
        )),
      )
      let hi = int.bitwise_and(high_half, 0xFFFFFFFF)
      Ok(<<
        0x28,
        0xB5,
        0x2F,
        0xFD,
        0xE0,
        lo:size(32)-little,
        hi:size(32)-little,
      >>)
    }
  }
}

fn build_raw_blocks(bytes: BitArray, total: Int) -> BitArray {
  case total {
    0 -> block_header(0, 0, True)
    _ -> emit_raw_blocks_loop(bytes, total, <<>>)
  }
}

fn emit_raw_blocks_loop(
  remaining_bytes: BitArray,
  remaining_size: Int,
  acc: BitArray,
) -> BitArray {
  case remaining_size {
    0 -> acc
    n -> {
      // Cap each chunk to the Huffman-eligible 1 KiB size whenever the
      // remaining input is big enough that splitting helps; otherwise
      // fall back to the 128 KiB raw/RLE chunk size.
      let chunk_size = case n > max_block_chunk {
        True -> max_block_chunk
        False -> n
      }
      let is_last = chunk_size == n
      let assert Ok(chunk) = bit_array.slice(remaining_bytes, 0, chunk_size)
      let assert Ok(rest) =
        bit_array.slice(
          remaining_bytes,
          chunk_size,
          bit_array.byte_size(remaining_bytes) - chunk_size,
        )
      let chunk_block = pick_best_block(chunk, chunk_size, is_last)
      emit_raw_blocks_loop(
        rest,
        remaining_size - chunk_size,
        bit_array.concat([acc, chunk_block]),
      )
    }
  }
}

/// Encode one ≤ 1 KiB chunk and return whichever block representation
/// is the smallest: Raw, RLE (when the chunk is one repeating byte),
/// or a Compressed_Block whose Literals_Section is Huffman-coded.
/// The Sequences_Section always carries `Number_of_Sequences = 0` so
/// literals ARE the output — no LZ77, no sequences.  Picking the
/// smallest of the three keeps the encoder strictly non-regressing on
/// uncompressible payloads.
fn pick_best_block(chunk: BitArray, chunk_size: Int, is_last: Bool) -> BitArray {
  let raw_block =
    bit_array.concat([
      block_header(chunk_size, 0, is_last),
      chunk,
    ])
  let raw_size = bit_array.byte_size(raw_block)

  let rle_block = case chunk_size >= 2, peek_uniform_byte(chunk) {
    True, Ok(byte) ->
      Some(bit_array.concat([block_header(chunk_size, 1, is_last), <<byte>>]))
    _, _ -> None
  }

  let huff_block = case
    chunk_size >= huffman_min_input_size
    && chunk_size <= huffman_1stream_max_regen
  {
    True -> try_huffman_block(chunk, chunk_size, is_last)
    False -> None
  }

  let huff_4stream_block = case
    chunk_size > huffman_1stream_max_regen && chunk_size >= 4
  {
    True -> try_huffman_block_4stream(chunk, chunk_size, is_last)
    False -> None
  }

  let candidates = [
    #(raw_size, raw_block),
    ..case rle_block {
      Some(rle) -> [#(bit_array.byte_size(rle), rle)]
      None -> []
    }
  ]
  let candidates = case huff_block {
    Some(h) -> [#(bit_array.byte_size(h), h), ..candidates]
    None -> candidates
  }
  let candidates = case huff_4stream_block {
    Some(h) -> [#(bit_array.byte_size(h), h), ..candidates]
    None -> candidates
  }
  pick_smallest_block(candidates)
}

fn pick_smallest_block(candidates: List(#(Int, BitArray))) -> BitArray {
  case candidates {
    [#(_, only)] -> only
    [first, ..rest] ->
      list.fold(rest, first, fn(acc, item) {
        case item.0 < acc.0 {
          True -> item
          False -> acc
        }
      }).1
    [] -> <<>>
  }
}

/// Try to encode `chunk` as a Huffman-compressed literals block.
/// Returns None when the chunk has fewer than two distinct bytes (a
/// trivial RLE case), when the resulting code would exceed zstd's
/// 11-bit tree-depth limit, or when the encoded form would not fit in
/// the 10-bit compressed-size field of the 1-stream literals header.
fn try_huffman_block(
  chunk: BitArray,
  chunk_size: Int,
  is_last: Bool,
) -> Option(BitArray) {
  let freqs = count_byte_frequencies(chunk)
  let distinct = list.length(list.filter(freqs, fn(p) { p.1 > 0 }))
  case distinct < 2 {
    True -> None
    False -> {
      case build_canonical_lengths(freqs) {
        Error(_) -> None
        Ok(#(lengths, max_bits)) ->
          case max_bits > huffman_max_tree_depth {
            True -> None
            False -> {
              // The direct-weight tree-description header byte is
              // `127 + N` (N = number of streamed weights = max_symbol
              // used).  That byte must stay within [128, 254] so the
              // decoder picks the direct-weight branch; if N > 127
              // the header overflows out of that range and the
              // decoder reinterprets the body as FSE weights.  Skip
              // Huffman in that case and let the chunk fall back to
              // Raw / RLE.
              let max_symbol_used = highest_nonzero_index(lengths, -1, 0)
              case max_symbol_used > 127 {
                True -> None
                False -> {
                  let code_table = assign_canonical_codes(lengths, max_bits)
                  let tree_bytes = serialize_huffman_tree(lengths)
                  let bitstream = encode_huffman_bitstream(chunk, code_table)
                  let comp_size =
                    bit_array.byte_size(tree_bytes)
                    + bit_array.byte_size(bitstream)
                  case comp_size >= huffman_max_block_compressed {
                    True -> None
                    False -> {
                      let literals_section =
                        build_compressed_literals_section(
                          chunk_size,
                          comp_size,
                          tree_bytes,
                          bitstream,
                        )
                      // Sequences_Section_Header for 0 sequences is a
                      // single 0x00 byte; no symbol-mode byte, no FSE
                      // descriptions, no bitstream.
                      let block_body =
                        bit_array.concat([literals_section, <<0x00>>])
                      let block_body_size = bit_array.byte_size(block_body)
                      Some(
                        bit_array.concat([
                          block_header(block_body_size, 2, is_last),
                          block_body,
                        ]),
                      )
                    }
                  }
                }
              }
            }
          }
      }
    }
  }
}

/// Same as `try_huffman_block`, but uses the 4-stream form (literals
/// header `size_format = 2`, 4-byte header, 14-bit regen / compressed
/// fields, 6-byte jump table before the four sub-bitstreams).  Lets
/// the encoder Huffman-code blocks above the 1-stream 1023-byte cap,
/// up to 16 383 bytes per block.  Splits the chunk into four parts
/// using zstd's `(N+3)/4, (N+2)/4, (N+1)/4, N/4` formula and runs the
/// existing 1-stream bitstream encoder once per part with the shared
/// Huffman code table.
fn try_huffman_block_4stream(
  chunk: BitArray,
  chunk_size: Int,
  is_last: Bool,
) -> Option(BitArray) {
  let freqs = count_byte_frequencies(chunk)
  let distinct = list.length(list.filter(freqs, fn(p) { p.1 > 0 }))
  case distinct < 2 {
    True -> None
    False ->
      case build_canonical_lengths(freqs) {
        Error(_) -> None
        Ok(#(lengths, max_bits)) ->
          case max_bits > huffman_max_tree_depth {
            True -> None
            False -> {
              let max_symbol_used = highest_nonzero_index(lengths, -1, 0)
              case max_symbol_used > 127 {
                True -> None
                False -> {
                  let code_table = assign_canonical_codes(lengths, max_bits)
                  let tree_bytes = serialize_huffman_tree(lengths)
                  let parts = split_chunk_4(chunk, chunk_size)
                  let #(p1, p2, p3, p4) = parts
                  let s1 = encode_huffman_bitstream(p1, code_table)
                  let s2 = encode_huffman_bitstream(p2, code_table)
                  let s3 = encode_huffman_bitstream(p3, code_table)
                  let s4 = encode_huffman_bitstream(p4, code_table)
                  let s1_size = bit_array.byte_size(s1)
                  let s2_size = bit_array.byte_size(s2)
                  let s3_size = bit_array.byte_size(s3)
                  let s4_size = bit_array.byte_size(s4)
                  // Jump table sizes must each fit in 16 bits so the
                  // decoder can read them as little-endian u16s.
                  case
                    s1_size > 0xFFFF || s2_size > 0xFFFF || s3_size > 0xFFFF
                  {
                    True -> None
                    False -> {
                      let jump_table = <<
                        s1_size:little-size(16),
                        s2_size:little-size(16),
                        s3_size:little-size(16),
                      >>
                      let comp_size =
                        bit_array.byte_size(tree_bytes)
                        + 6
                        + s1_size
                        + s2_size
                        + s3_size
                        + s4_size
                      case comp_size > huffman_4stream_max_compressed {
                        True -> None
                        False -> {
                          let literals_section =
                            build_compressed_literals_section_4stream(
                              chunk_size,
                              comp_size,
                              tree_bytes,
                              jump_table,
                              s1,
                              s2,
                              s3,
                              s4,
                            )
                          let block_body =
                            bit_array.concat([literals_section, <<0x00>>])
                          let block_body_size = bit_array.byte_size(block_body)
                          Some(
                            bit_array.concat([
                              block_header(block_body_size, 2, is_last),
                              block_body,
                            ]),
                          )
                        }
                      }
                    }
                  }
                }
              }
            }
          }
      }
  }
}

fn split_chunk_4(
  chunk: BitArray,
  chunk_size: Int,
) -> #(BitArray, BitArray, BitArray, BitArray) {
  // The zstd reference and our `decode_four_streams` decoder both use
  // `per_stream = (N+3)/4` for EACH of the first three substreams,
  // with stream 4 getting the remainder.  The varying RFC formulas
  // `(N+3)/4, (N+2)/4, (N+1)/4, N/4` describe equivalent splits for
  // N divisible by 4 but diverge otherwise — we follow the reference
  // implementation to keep the encoder and decoder in lockstep.
  let per_stream = { chunk_size + 3 } / 4
  let s4_len = chunk_size - per_stream * 3
  let assert Ok(p1) = bit_array.slice(chunk, 0, per_stream)
  let assert Ok(p2) = bit_array.slice(chunk, per_stream, per_stream)
  let assert Ok(p3) = bit_array.slice(chunk, per_stream * 2, per_stream)
  let assert Ok(p4) = bit_array.slice(chunk, per_stream * 3, s4_len)
  #(p1, p2, p3, p4)
}

/// Build the 4-stream literals section: 4-byte header (size_format = 2,
/// 14-bit regen / 14-bit compressed) followed by the Huffman tree,
/// the 6-byte jump table (`stream1_size`, `stream2_size`,
/// `stream3_size` each as LE u16; stream 4's size is derived by the
/// decoder from `total - 6 - sum`), and the four sub-bitstreams.
fn build_compressed_literals_section_4stream(
  regen_size: Int,
  comp_size: Int,
  tree_bytes: BitArray,
  jump_table: BitArray,
  s1: BitArray,
  s2: BitArray,
  s3: BitArray,
  s4: BitArray,
) -> BitArray {
  // Header layout (matches `parse_compressed_literals_header`
  // size_format = 2):
  //   b0: bits 0-1 = block_type=2, bits 2-3 = size_format=2,
  //       bits 4-7 = regen_size[0..3]
  //   b1: bits 0-7 = regen_size[4..11]
  //   b2: bits 0-1 = regen_size[12..13], bits 2-7 = comp_size[0..5]
  //   b3: bits 0-7 = comp_size[6..13]
  let b0 =
    int.bitwise_and(
      int.bitwise_or(
        int.bitwise_or(2, int.bitwise_shift_left(2, 2)),
        int.bitwise_shift_left(int.bitwise_and(regen_size, 0xF), 4),
      ),
      0xFF,
    )
  let b1 = int.bitwise_and(int.bitwise_shift_right(regen_size, 4), 0xFF)
  let regen_high_2 =
    int.bitwise_and(int.bitwise_shift_right(regen_size, 12), 0x3)
  let comp_low_6 = int.bitwise_and(comp_size, 0x3F)
  let b2 =
    int.bitwise_and(
      int.bitwise_or(regen_high_2, int.bitwise_shift_left(comp_low_6, 2)),
      0xFF,
    )
  let b3 = int.bitwise_and(int.bitwise_shift_right(comp_size, 6), 0xFF)
  bit_array.concat([<<b0, b1, b2, b3>>, tree_bytes, jump_table, s1, s2, s3, s4])
}

fn highest_nonzero_index(lengths: List(Int), best: Int, pos: Int) -> Int {
  case lengths {
    [] -> best
    [head, ..rest] ->
      case head > 0 {
        True -> highest_nonzero_index(rest, pos, pos + 1)
        False -> highest_nonzero_index(rest, best, pos + 1)
      }
  }
}

// -- Huffman literals support ------------------------------------------

/// Count `chunk`'s byte frequencies as a list of `#(symbol, count)`
/// pairs for symbols 0..255 in ascending order.  Symbols with zero
/// occurrences are kept (they're filtered before tree building) so the
/// caller can iterate the full 0..255 range without separate handling.
fn count_byte_frequencies(chunk: BitArray) -> List(#(Int, Int)) {
  let initial = empty_freq_dict(0, dict.new())
  let table = collect_frequencies(chunk, initial)
  count_freqs_to_list(table, 0, [])
}

fn empty_freq_dict(symbol: Int, acc: dict.Dict(Int, Int)) -> dict.Dict(Int, Int) {
  case symbol {
    256 -> acc
    _ -> empty_freq_dict(symbol + 1, dict.insert(acc, symbol, 0))
  }
}

fn collect_frequencies(
  chunk: BitArray,
  acc: dict.Dict(Int, Int),
) -> dict.Dict(Int, Int) {
  case chunk {
    <<byte, rest:bytes>> -> {
      let current = case dict.get(acc, byte) {
        Ok(v) -> v
        Error(_) -> 0
      }
      collect_frequencies(rest, dict.insert(acc, byte, current + 1))
    }
    _ -> acc
  }
}

fn count_freqs_to_list(
  table: dict.Dict(Int, Int),
  symbol: Int,
  acc: List(#(Int, Int)),
) -> List(#(Int, Int)) {
  case symbol {
    256 -> list.reverse(acc)
    _ -> {
      let count = case dict.get(table, symbol) {
        Ok(v) -> v
        Error(_) -> 0
      }
      count_freqs_to_list(table, symbol + 1, [#(symbol, count), ..acc])
    }
  }
}

type HuffNode {
  HuffLeaf(symbol: Int)
  HuffInternal(left: HuffNode, right: HuffNode)
}

/// Build canonical Huffman code lengths for `freqs`, returning a list
/// of 256 lengths (0 for unused symbols).  Standard Huffman tree
/// construction via insertion-sort; bails out with `Error(Nil)` when
/// the resulting tree exceeds the 11-bit depth limit so the caller
/// can fall back to Raw / RLE.
fn build_canonical_lengths(
  freqs: List(#(Int, Int)),
) -> Result(#(List(Int), Int), Nil) {
  let active =
    list.filter_map(freqs, fn(p) {
      case p.1 > 0 {
        True -> Ok(#(p.1, HuffLeaf(p.0)))
        False -> Error(Nil)
      }
    })
  let sorted = list.sort(active, fn(a, b) { int.compare(a.0, b.0) })
  case sorted {
    [] -> Error(Nil)
    [#(_, single_node)] -> {
      // Single distinct symbol — emit a 1-bit code so the canonical
      // assignment has at least one bit to allocate.
      let single = case single_node {
        HuffLeaf(s) -> s
        _ -> 0
      }
      let lengths = build_length_list(dict.insert(dict.new(), single, 1), 0, [])
      Ok(#(lengths, 1))
    }
    _ -> {
      let root = huffman_merge(sorted)
      let lengths_dict = extract_lengths(root, 0, dict.new())
      let max_bits = max_length_in_dict(lengths_dict)
      let lengths = build_length_list(lengths_dict, 0, [])
      Ok(#(lengths, max_bits))
    }
  }
}

fn huffman_merge(nodes: List(#(Int, HuffNode))) -> HuffNode {
  case nodes {
    [#(_, single)] -> single
    [a, b, ..rest] -> {
      let combined = #(a.0 + b.0, HuffInternal(a.1, b.1))
      huffman_merge(insert_node_sorted(combined, rest))
    }
    _ -> HuffLeaf(0)
  }
}

fn insert_node_sorted(
  item: #(Int, HuffNode),
  nodes: List(#(Int, HuffNode)),
) -> List(#(Int, HuffNode)) {
  case nodes {
    [] -> [item]
    [head, ..rest] ->
      case item.0 <= head.0 {
        True -> [item, head, ..rest]
        False -> [head, ..insert_node_sorted(item, rest)]
      }
  }
}

fn extract_lengths(
  node: HuffNode,
  depth: Int,
  acc: dict.Dict(Int, Int),
) -> dict.Dict(Int, Int) {
  case node {
    HuffLeaf(sym) -> {
      let d = case depth {
        0 -> 1
        _ -> depth
      }
      dict.insert(acc, sym, d)
    }
    HuffInternal(l, r) -> {
      let acc = extract_lengths(l, depth + 1, acc)
      extract_lengths(r, depth + 1, acc)
    }
  }
}

fn max_length_in_dict(lengths: dict.Dict(Int, Int)) -> Int {
  dict.fold(lengths, 0, fn(acc, _key, value) {
    case value > acc {
      True -> value
      False -> acc
    }
  })
}

fn build_length_list(
  lengths: dict.Dict(Int, Int),
  symbol: Int,
  acc: List(Int),
) -> List(Int) {
  case symbol {
    256 -> list.reverse(acc)
    _ -> {
      let len = case dict.get(lengths, symbol) {
        Ok(v) -> v
        Error(_) -> 0
      }
      build_length_list(lengths, symbol + 1, [len, ..acc])
    }
  }
}

/// Build the encoder's `symbol → #(code_value, num_bits)` table from
/// the canonical lengths.  zstd's lookup table is filled in order
/// (length DESC, symbol ASC), so the encoder's code values are simply
/// the table slot indices, right-shifted by `max_bits - num_bits` to
/// drop the table's low-order bits (which the decoder treats as
/// "don't care" once it has consumed `num_bits` bits).
fn assign_canonical_codes(
  lengths: List(Int),
  max_bits: Int,
) -> dict.Dict(Int, #(Int, Int)) {
  let with_index =
    list.index_map(lengths, fn(len, sym) { #(sym, len) })
    |> list.filter(fn(p) { p.1 > 0 })
  let sorted =
    list.sort(with_index, fn(a, b) {
      // Mirror the decoder's fill_lookup order: length DESC, symbol ASC.
      case int.compare(b.1, a.1) {
        order.Eq -> int.compare(a.0, b.0)
        ord -> ord
      }
    })
  assign_codes_loop(sorted, max_bits, 0, dict.new())
}

fn assign_codes_loop(
  sorted: List(#(Int, Int)),
  max_bits: Int,
  slot: Int,
  acc: dict.Dict(Int, #(Int, Int)),
) -> dict.Dict(Int, #(Int, Int)) {
  case sorted {
    [] -> acc
    [#(sym, len), ..rest] -> {
      let span = int.bitwise_shift_left(1, max_bits - len)
      let code = int.bitwise_shift_right(slot, max_bits - len)
      assign_codes_loop(
        rest,
        max_bits,
        slot + span,
        dict.insert(acc, sym, #(code, len)),
      )
    }
  }
}

fn max_length_in_list(lengths: List(Int), acc: Int) -> Int {
  case lengths {
    [] -> acc
    [head, ..rest] ->
      case head > acc {
        True -> max_length_in_list(rest, head)
        False -> max_length_in_list(rest, acc)
      }
  }
}

fn trim_trailing_zero_weights(reversed: List(Int), acc: List(Int)) -> List(Int) {
  case reversed, acc {
    [], _ -> acc
    [0, ..rest], [] -> trim_trailing_zero_weights(rest, [])
    [head, ..rest], _ -> trim_trailing_zero_weights(rest, [head, ..acc])
  }
}

fn drop_last_weight(weights: List(Int), acc: List(Int)) -> List(Int) {
  case weights {
    [] -> list.reverse(acc)
    [_last] -> list.reverse(acc)
    [head, ..rest] -> drop_last_weight(rest, [head, ..acc])
  }
}

fn pack_weights_4bit(weights: List(Int), acc: BitArray) -> BitArray {
  case weights {
    [] -> acc
    [single] -> {
      // Odd weight count — pad low nibble with 0.
      let byte = int.bitwise_shift_left(single, 4)
      <<acc:bits, byte>>
    }
    [high, low, ..rest] -> {
      let byte = int.bitwise_or(int.bitwise_shift_left(high, 4), low)
      pack_weights_4bit(rest, <<acc:bits, byte>>)
    }
  }
}

/// Build the bitstream a zstd Huffman decoder reads from the END
/// backward.  We iterate input in REVERSE order, push each code into a
/// shift register from the LOW end, flush low bytes when full, and
/// finally append a 1-bit terminator that the decoder finds via
/// "highest set bit of the last byte".
fn encode_huffman_bitstream(
  chunk: BitArray,
  codes: dict.Dict(Int, #(Int, Int)),
) -> BitArray {
  let bytes = bit_array_to_list_forward(chunk, [])
  let reversed = list.reverse(bytes)
  let #(buf, bits, out) = emit_codes_reverse(reversed, codes, 0, 0, <<>>)
  // Append the terminator at the next position.
  let buf2 = int.bitwise_or(buf, int.bitwise_shift_left(1, bits))
  let bits2 = bits + 1
  flush_final_bits(buf2, bits2, out)
}

fn bit_array_to_list_forward(bytes: BitArray, acc: List(Int)) -> List(Int) {
  case bytes {
    <<byte, rest:bytes>> -> bit_array_to_list_forward(rest, [byte, ..acc])
    _ -> list.reverse(acc)
  }
}

fn emit_codes_reverse(
  bytes_rev: List(Int),
  codes: dict.Dict(Int, #(Int, Int)),
  buf: Int,
  bits: Int,
  out: BitArray,
) -> #(Int, Int, BitArray) {
  case bytes_rev {
    [] -> #(buf, bits, out)
    [byte, ..rest] -> {
      let #(code, len) = case dict.get(codes, byte) {
        Ok(v) -> v
        Error(_) -> #(0, 0)
      }
      let new_buf = int.bitwise_or(buf, int.bitwise_shift_left(code, bits))
      let new_bits = bits + len
      let #(flushed_buf, flushed_bits, flushed_out) =
        flush_full_bytes(new_buf, new_bits, out)
      emit_codes_reverse(rest, codes, flushed_buf, flushed_bits, flushed_out)
    }
  }
}

fn flush_full_bytes(buf: Int, bits: Int, out: BitArray) -> #(Int, Int, BitArray) {
  case bits >= 8 {
    True -> {
      let byte = int.bitwise_and(buf, 0xFF)
      let new_buf = int.bitwise_shift_right(buf, 8)
      flush_full_bytes(new_buf, bits - 8, <<out:bits, byte>>)
    }
    False -> #(buf, bits, out)
  }
}

fn flush_final_bits(buf: Int, bits: Int, out: BitArray) -> BitArray {
  case bits {
    0 -> out
    _ -> {
      // Whatever bits remain become the LAST byte, with the
      // terminator's `1` bit at the highest occupied position.  The
      // unused high bits stay 0 so the decoder finds the terminator
      // at the right spot.
      let byte = int.bitwise_and(buf, 0xFF)
      let new_buf = int.bitwise_shift_right(buf, 8)
      let new_bits = case bits > 8 {
        True -> bits - 8
        False -> 0
      }
      flush_final_bits(new_buf, new_bits, <<out:bits, byte>>)
    }
  }
}

/// Serialize the Huffman tree in the direct-weight form: header byte
/// `127 + num_weights` (placing it in 128..254) followed by 4-bit
/// weights packed two-per-byte.  The last weight is implied — it's
/// derived from the constraint that `sum(2^(weight-1)) = 2^max_bits`.
fn serialize_huffman_tree(lengths: List(Int)) -> BitArray {
  let max_bits = max_length_in_list(lengths, 0)
  // weight = max_bits + 1 - length (for length > 0); 0 for unused.
  let weights =
    list.map(lengths, fn(l) {
      case l {
        0 -> 0
        _ -> max_bits + 1 - l
      }
    })
  let trimmed = trim_trailing_zero_weights(list.reverse(weights), [])
  // Drop the last weight (it's implied by the Kraft balance check).
  let serialized = drop_last_weight(trimmed, [])
  let num_serialized = list.length(serialized)
  // Header_byte = 127 + N where N = number of weights explicitly
  // streamed; the (N+1)-th weight is implied by the Kraft balance the
  // decoder reconstructs in `weights_with_implied_last`.
  let header_byte = 127 + num_serialized
  let packed = pack_weights_4bit(serialized, <<>>)
  <<header_byte, packed:bits>>
}

/// Pack the Literals_Section_Header for the 1-stream Compressed form
/// (`size_format = 0`): 3 bytes carrying block_type=2, size_format=0,
/// 10-bit regenerated_size, and 10-bit compressed_size; followed by
/// the Huffman tree description and the bitstream.
fn build_compressed_literals_section(
  regenerated_size: Int,
  compressed_size: Int,
  tree_bytes: BitArray,
  bitstream: BitArray,
) -> BitArray {
  // Header layout (low bit first):
  //   bits 0-1  : block_type = 2
  //   bits 2-3  : size_format = 0
  //   bits 4-13 : regenerated_size (10 bits)
  //   bits 14-23: compressed_size (10 bits)
  let b0 =
    int.bitwise_and(
      int.bitwise_or(
        int.bitwise_or(2, 0),
        int.bitwise_shift_left(int.bitwise_and(regenerated_size, 0xF), 4),
      ),
      0xFF,
    )
  let regen_high = int.bitwise_shift_right(regenerated_size, 4)
  let comp_low = int.bitwise_and(compressed_size, 0x3F)
  let b1 =
    int.bitwise_and(
      int.bitwise_or(
        int.bitwise_and(regen_high, 0x3F),
        int.bitwise_shift_left(comp_low, 6),
      ),
      0xFF,
    )
  let b2 = int.bitwise_and(int.bitwise_shift_right(compressed_size, 2), 0xFF)
  bit_array.concat([<<b0, b1, b2>>, tree_bytes, bitstream])
}

/// Returns the single byte the whole chunk repeats, or Error if the
/// chunk has more than one distinct value.
fn peek_uniform_byte(bytes: BitArray) -> Result(Int, Nil) {
  case bytes {
    <<first, rest:bytes>> -> uniform_byte_loop(first, rest)
    _ -> Error(Nil)
  }
}

fn uniform_byte_loop(byte: Int, rest: BitArray) -> Result(Int, Nil) {
  case rest {
    <<>> -> Ok(byte)
    <<b, more:bytes>> if b == byte -> uniform_byte_loop(byte, more)
    _ -> Error(Nil)
  }
}

fn block_header(block_size: Int, block_type: Int, is_last: Bool) -> BitArray {
  let last_bit = case is_last {
    True -> 1
    False -> 0
  }
  // header layout: [block_size:21][block_type:2][last:1]
  let block_header_value =
    int.bitwise_or(
      int.bitwise_or(
        int.bitwise_shift_left(block_size, 3),
        int.bitwise_shift_left(block_type, 1),
      ),
      last_bit,
    )
  let bh0 = int.bitwise_and(block_header_value, 0xFF)
  let bh1 =
    int.bitwise_and(int.bitwise_shift_right(block_header_value, 8), 0xFF)
  let bh2 =
    int.bitwise_and(int.bitwise_shift_right(block_header_value, 16), 0xFF)
  <<bh0, bh1, bh2>>
}

/// Decode a Zstandard frame using default limits.
pub fn decode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  decode_with_limits(bytes: bytes, limits: limit.default())
}

/// Decode a Zstandard frame using explicit limits.  Per RFC 8478 §3,
/// a zstd "byte stream" is one or more frames concatenated; the
/// decoder walks the entire input, appending each frame's payload to
/// the result.
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

  decode_frames_loop(bytes, <<>>, 0, limits)
}

fn decode_frames_loop(
  bytes: BitArray,
  acc: BitArray,
  accumulated_size: Int,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  // Skippable frames (RFC 8478 §3.1.2) have magic 0x184D2A5X for X
  // in 0..F.  The 4-byte LE Frame_Size that follows tells us how
  // many bytes of User_Data to skip.  The decoder must skip them
  // and then look for the next frame.
  case bytes {
    <<m:little-unsigned-size(32), _:bytes>>
      if m >= 0x184D2A50 && m <= 0x184D2A5F
    -> skip_skippable_frame(bytes, acc, accumulated_size, limits)
    _ -> decode_data_frame(bytes, acc, accumulated_size, limits)
  }
}

fn decode_data_frame(
  bytes: BitArray,
  acc: BitArray,
  accumulated_size: Int,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  use #(checksum_flag, rest) <- result.try(parse_frame_header(bytes))
  use #(output, rest) <- result.try(decode_blocks(
    rest,
    <<>>,
    limits,
    initial_block_state,
  ))
  use rest <- result.try(consume_checksum_returning_rest(rest, checksum_flag))
  let next_size = accumulated_size + bit_array.byte_size(output)
  case next_size > limit.max_output_bytes(limits) {
    True ->
      Error(error.CodecLimitExceeded(
        limit: "max_output_bytes",
        actual: next_size,
      ))
    False -> {
      let acc = bit_array.concat([acc, output])
      case bit_array.byte_size(rest) {
        0 -> Ok(acc)
        _ -> decode_frames_loop(rest, acc, next_size, limits)
      }
    }
  }
}

fn skip_skippable_frame(
  bytes: BitArray,
  acc: BitArray,
  accumulated_size: Int,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  case bytes {
    <<_magic:bytes-size(4), frame_size:little-unsigned-size(32), rest:bytes>> ->
      case bit_array.byte_size(rest) >= frame_size {
        False ->
          Error(error.CodecInvalidData(
            message: "zstd skippable frame body is shorter than the declared Frame_Size",
          ))
        True ->
          case
            bit_array.slice(
              rest,
              frame_size,
              bit_array.byte_size(rest) - frame_size,
            )
          {
            Ok(after_skip) ->
              case bit_array.byte_size(after_skip) {
                0 -> Ok(acc)
                _ ->
                  decode_frames_loop(after_skip, acc, accumulated_size, limits)
              }
            Error(_) ->
              Error(error.CodecInvalidData(
                message: "zstd skippable frame slice failed",
              ))
          }
      }
    _ ->
      Error(error.CodecInvalidData(
        message: "zstd skippable frame header is shorter than 8 bytes",
      ))
  }
}

fn consume_checksum_returning_rest(
  bytes: BitArray,
  checksum_flag: Bool,
) -> Result(BitArray, error.CodecError) {
  case checksum_flag {
    False -> Ok(bytes)
    True ->
      case bytes {
        <<_crc:bytes-size(4), rest:bytes>> -> Ok(rest)
        _ ->
          Error(error.CodecInvalidData(
            message: "zstd content checksum is shorter than 4 bytes",
          ))
      }
  }
}

// -- frame header -------------------------------------------------------

fn parse_frame_header(
  bytes: BitArray,
) -> Result(#(Bool, BitArray), error.CodecError) {
  case bytes {
    <<m:little-unsigned-size(32), rest:bytes>> if m == magic ->
      parse_frame_descriptor(rest)
    _ -> Error(error.CodecInvalidData(message: "missing zstd frame magic"))
  }
}

fn parse_frame_descriptor(
  bytes: BitArray,
) -> Result(#(Bool, BitArray), error.CodecError) {
  case bytes {
    <<descriptor, rest:bytes>> -> {
      let fcs_flag = int.bitwise_shift_right(descriptor, 6)
      let single_segment = int.bitwise_and(descriptor, 0x20) != 0
      let reserved_bit = int.bitwise_and(descriptor, 0x08) != 0
      let checksum_flag = int.bitwise_and(descriptor, 0x04) != 0
      let dict_id_flag = int.bitwise_and(descriptor, 0x03)
      use <- bool.guard(
        when: reserved_bit,
        return: Error(error.CodecInvalidData(
          message: "zstd reserved descriptor bit must be zero",
        )),
      )
      use rest <- result.try(case single_segment {
        True -> Ok(rest)
        False -> skip_window_descriptor(rest)
      })
      use rest <- result.try(skip_dictionary_id(rest, dict_id_flag))
      use rest <- result.try(skip_frame_content_size(
        rest,
        fcs_flag,
        single_segment,
      ))
      Ok(#(checksum_flag, rest))
    }
    _ -> Error(error.CodecInvalidData(message: "truncated zstd frame header"))
  }
}

fn skip_window_descriptor(bytes: BitArray) -> Result(BitArray, error.CodecError) {
  case bytes {
    <<_window, rest:bytes>> -> Ok(rest)
    _ ->
      Error(error.CodecInvalidData(message: "truncated zstd window descriptor"))
  }
}

fn skip_dictionary_id(
  bytes: BitArray,
  flag: Int,
) -> Result(BitArray, error.CodecError) {
  let size = case flag {
    0 -> 0
    1 -> 1
    2 -> 2
    3 -> 4
    _ -> 0
  }
  drop_bytes(bytes, size, "zstd dictionary id")
}

fn skip_frame_content_size(
  bytes: BitArray,
  flag: Int,
  single_segment: Bool,
) -> Result(BitArray, error.CodecError) {
  let size = case flag {
    0 ->
      case single_segment {
        True -> 1
        False -> 0
      }
    1 -> 2
    2 -> 4
    3 -> 8
    _ -> 0
  }
  drop_bytes(bytes, size, "zstd frame content size")
}

// -- block driver -------------------------------------------------------

/// Snapshot of all per-frame block-to-block state that the zstd
/// decoder must thread between successive compressed blocks:
/// the most recently parsed Huffman literal tree (for treeless
/// literals), the LL / OF / ML FSE tables (for Repeat_Mode), and
/// the reversed concatenation of every previous block's output
/// so this block's match copies can reach back into it.
type BlockState {
  BlockState(
    huffman: Option(huf.Tree),
    sequences: SeqTablesState,
    previous_output_rev: List(Int),
    /// Repeated-offset triple (rep0, rep1, rep2) persisted across
    /// blocks within a frame.  RFC 8478 §3.1.1.5: "Repeated offsets
    /// are maintained across blocks (but not across frames)."  The
    /// per-frame initial values are (1, 4, 8).
    reps: #(Int, Int, Int),
  )
}

type SeqTablesState {
  SeqTablesState(
    ll: Option(#(dict.Dict(Int, fse.StateEntry), Int)),
    of: Option(#(dict.Dict(Int, fse.StateEntry), Int)),
    ml: Option(#(dict.Dict(Int, fse.StateEntry), Int)),
  )
}

const initial_block_state: BlockState = BlockState(
  huffman: None,
  sequences: SeqTablesState(ll: None, of: None, ml: None),
  previous_output_rev: [],
  reps: #(1, 4, 8),
)

fn decode_blocks(
  bytes: BitArray,
  output: BitArray,
  limits: limit.Limits,
  state: BlockState,
) -> Result(#(BitArray, BitArray), error.CodecError) {
  case bytes {
    <<b0, b1, b2, rest:bytes>> -> {
      let header =
        int.bitwise_or(
          b0,
          int.bitwise_or(
            int.bitwise_shift_left(b1, 8),
            int.bitwise_shift_left(b2, 16),
          ),
        )
      let last = int.bitwise_and(header, 0x1) == 1
      let block_type = int.bitwise_and(int.bitwise_shift_right(header, 1), 0x3)
      let block_size = int.bitwise_shift_right(header, 3)
      use #(plain, rest, next_state) <- result.try(decode_one_block(
        rest,
        block_type,
        block_size,
        state,
      ))
      use new_output <- result.try(append_with_limit(output, plain, limits))
      case last {
        True -> Ok(#(new_output, rest))
        False -> decode_blocks(rest, new_output, limits, next_state)
      }
    }
    _ -> Error(error.CodecInvalidData(message: "truncated zstd block header"))
  }
}

fn decode_one_block(
  bytes: BitArray,
  block_type: Int,
  block_size: Int,
  state: BlockState,
) -> Result(#(BitArray, BitArray, BlockState), error.CodecError) {
  case block_type {
    0 ->
      decode_raw_block(bytes, block_size)
      |> result.map(fn(pair) {
        let #(plain, rest) = pair
        #(plain, rest, append_block_output(state, plain))
      })
    1 ->
      decode_rle_block(bytes, block_size)
      |> result.map(fn(pair) {
        let #(plain, rest) = pair
        #(plain, rest, append_block_output(state, plain))
      })
    2 -> decode_compressed_block(bytes, block_size, state)
    _ -> Error(error.CodecInvalidData(message: "zstd reserved block type 3"))
  }
}

/// Prepend this block's output bytes to the running per-frame
/// reversed output so the next block's matches can reach back.
fn append_block_output(state: BlockState, plain: BitArray) -> BlockState {
  BlockState(
    ..state,
    previous_output_rev: prepend_bytes(plain, state.previous_output_rev),
  )
}

// -- compressed block --------------------------------------------------

fn decode_compressed_block(
  bytes: BitArray,
  block_size: Int,
  state: BlockState,
) -> Result(#(BitArray, BitArray, BlockState), error.CodecError) {
  use payload <- result.try(slice_or_error(
    bytes,
    0,
    block_size,
    "zstd compressed block payload",
  ))
  let assert Ok(rest) =
    bit_array.slice(bytes, block_size, bit_array.byte_size(bytes) - block_size)

  use #(literals, after_literals, next_huffman) <- result.try(
    parse_literals_section(payload, state.huffman),
  )
  use #(plain, next_sequences, next_reps) <- result.try(
    parse_and_apply_sequences(
      after_literals,
      literals,
      state.sequences,
      state.previous_output_rev,
      state.reps,
    ),
  )
  Ok(#(
    plain,
    rest,
    BlockState(
      huffman: next_huffman,
      sequences: next_sequences,
      previous_output_rev: prepend_bytes(plain, state.previous_output_rev),
      reps: next_reps,
    ),
  ))
}

// -- literals section --------------------------------------------------

fn parse_literals_section(
  bytes: BitArray,
  prev_tree: Option(huf.Tree),
) -> Result(#(BitArray, BitArray, Option(huf.Tree)), error.CodecError) {
  case bytes {
    <<header_byte, _:bytes>> -> {
      let literals_block_type = int.bitwise_and(header_byte, 0x3)
      let size_format =
        int.bitwise_and(int.bitwise_shift_right(header_byte, 2), 0x3)
      case literals_block_type {
        0 ->
          parse_raw_or_rle_literals(bytes, header_byte, size_format, False)
          |> result.map(fn(pair) { #(pair.0, pair.1, prev_tree) })
        1 ->
          parse_raw_or_rle_literals(bytes, header_byte, size_format, True)
          |> result.map(fn(pair) { #(pair.0, pair.1, prev_tree) })
        2 ->
          parse_compressed_literals(
            bytes,
            header_byte,
            size_format,
            False,
            prev_tree,
          )
        _ ->
          parse_compressed_literals(
            bytes,
            header_byte,
            size_format,
            True,
            prev_tree,
          )
      }
    }
    _ ->
      Error(error.CodecInvalidData(message: "truncated zstd literals header"))
  }
}

/// Parsed metadata for a compressed or treeless literals block.
type CompressedLiteralsHeader {
  CompressedLiteralsHeader(
    /// Number of literal bytes to materialise.
    regenerated_size: Int,
    /// Number of bytes after the literals section header that make
    /// up the Huffman_Tree_Description (if any), Jump_Table (if
    /// `streams == 4`), and per-stream compressed bitstreams.
    compressed_size: Int,
    /// Number of compressed Huffman bitstreams (1 or 4).
    streams: Int,
    /// Bytes consumed by the literals section header itself
    /// (3, 4, or 5 depending on the size format).
    header_bytes: Int,
  )
}

fn parse_compressed_literals(
  bytes: BitArray,
  header_byte: Int,
  size_format: Int,
  treeless: Bool,
  prev_tree: Option(huf.Tree),
) -> Result(#(BitArray, BitArray, Option(huf.Tree)), error.CodecError) {
  use header <- result.try(parse_compressed_literals_header(
    bytes,
    header_byte,
    size_format,
  ))
  case treeless {
    True -> decode_treeless_literals_block(bytes, header, prev_tree)
    False -> decode_huffman_literals_block(bytes, header)
  }
}

fn decode_huffman_literals_block(
  bytes: BitArray,
  header: CompressedLiteralsHeader,
) -> Result(#(BitArray, BitArray, Option(huf.Tree)), error.CodecError) {
  // Slice the literals section payload out of the surrounding block
  // so the Huffman tree parser stops at the right boundary.
  let section_total = header.header_bytes + header.compressed_size
  use section <- result.try(slice_or_error(
    bytes,
    0,
    section_total,
    "zstd compressed literals section body",
  ))
  let assert Ok(after_section) =
    bit_array.slice(
      bytes,
      section_total,
      bit_array.byte_size(bytes) - section_total,
    )

  let assert Ok(tree_bytes) =
    bit_array.slice(
      section,
      header.header_bytes,
      section_total - header.header_bytes,
    )
  case huf.read_tree(tree_bytes) {
    Error(reason) -> Error(huf_error_to_codec(reason))
    Ok(#(tree, tree_consumed)) -> {
      let bitstream_size = header.compressed_size - tree_consumed
      use bitstream_bytes <- result.try(slice_or_error(
        section,
        header.header_bytes + tree_consumed,
        bitstream_size,
        "zstd Huffman literal bitstream",
      ))
      use literals <- result.try(decode_huffman_streams(
        tree,
        bitstream_bytes,
        header,
      ))
      Ok(#(literals, after_section, Some(tree)))
    }
  }
}

fn decode_treeless_literals_block(
  bytes: BitArray,
  header: CompressedLiteralsHeader,
  prev_tree: Option(huf.Tree),
) -> Result(#(BitArray, BitArray, Option(huf.Tree)), error.CodecError) {
  case prev_tree {
    None ->
      Error(error.CodecInvalidData(
        message: "zstd treeless literals without a prior Huffman tree",
      ))
    Some(tree) -> {
      let section_total = header.header_bytes + header.compressed_size
      use section <- result.try(slice_or_error(
        bytes,
        0,
        section_total,
        "zstd treeless literals section body",
      ))
      let assert Ok(after_section) =
        bit_array.slice(
          bytes,
          section_total,
          bit_array.byte_size(bytes) - section_total,
        )
      // Treeless literals omit the Huffman_Tree_Description so the
      // whole compressed_size is the bitstream payload.
      use bitstream_bytes <- result.try(slice_or_error(
        section,
        header.header_bytes,
        header.compressed_size,
        "zstd treeless literal bitstream",
      ))
      use literals <- result.try(decode_huffman_streams(
        tree,
        bitstream_bytes,
        header,
      ))
      Ok(#(literals, after_section, prev_tree))
    }
  }
}

fn decode_huffman_streams(
  tree: huf.Tree,
  bitstream_bytes: BitArray,
  header: CompressedLiteralsHeader,
) -> Result(BitArray, error.CodecError) {
  case header.streams {
    1 ->
      huf.decode_stream(tree, bitstream_bytes, header.regenerated_size)
      |> result.map_error(huf_error_to_codec)
    _ ->
      huf.decode_four_streams(tree, bitstream_bytes, header.regenerated_size)
      |> result.map_error(huf_error_to_codec)
  }
}

fn huf_error_to_codec(err: huf.HufError) -> error.CodecError {
  case err {
    huf.HufTruncated(message) -> error.CodecInvalidData(message: message)
    huf.HufInvalidWeights(message) -> error.CodecInvalidData(message: message)
    huf.HufBitstreamError(_) ->
      error.CodecInvalidData(message: "zstd Huffman bitstream truncated")
    huf.HufUnsupported(feature) -> error.CodecNotImplemented(feature: feature)
  }
}

fn parse_compressed_literals_header(
  bytes: BitArray,
  header_byte: Int,
  size_format: Int,
) -> Result(CompressedLiteralsHeader, error.CodecError) {
  case size_format {
    0 ->
      // 3-byte header, 1 stream, 10-bit regen and compressed sizes.
      case bytes {
        <<_, b1, b2, _:bytes>> -> {
          let high_bits_of_header_byte = int.bitwise_shift_right(header_byte, 4)
          let regenerated_size =
            int.bitwise_or(
              high_bits_of_header_byte,
              int.bitwise_shift_left(int.bitwise_and(b1, 0x3F), 4),
            )
          let compressed_size =
            int.bitwise_or(
              int.bitwise_shift_right(b1, 6),
              int.bitwise_shift_left(b2, 2),
            )
          Ok(CompressedLiteralsHeader(
            regenerated_size: regenerated_size,
            compressed_size: compressed_size,
            streams: 1,
            header_bytes: 3,
          ))
        }
        _ ->
          Error(error.CodecInvalidData(
            message: "truncated zstd compressed-literals 3-byte header",
          ))
      }
    1 ->
      // 3-byte header, 4 streams, 10-bit regen and compressed sizes.
      case bytes {
        <<_, b1, b2, _:bytes>> -> {
          let high_bits_of_header_byte = int.bitwise_shift_right(header_byte, 4)
          let regenerated_size =
            int.bitwise_or(
              high_bits_of_header_byte,
              int.bitwise_shift_left(int.bitwise_and(b1, 0x3F), 4),
            )
          let compressed_size =
            int.bitwise_or(
              int.bitwise_shift_right(b1, 6),
              int.bitwise_shift_left(b2, 2),
            )
          Ok(CompressedLiteralsHeader(
            regenerated_size: regenerated_size,
            compressed_size: compressed_size,
            streams: 4,
            header_bytes: 3,
          ))
        }
        _ ->
          Error(error.CodecInvalidData(
            message: "truncated zstd compressed-literals 3-byte header",
          ))
      }
    2 ->
      // 4-byte header, 4 streams, 14-bit regen and compressed sizes.
      case bytes {
        <<_, b1, b2, b3, _:bytes>> -> {
          let high_bits_of_header_byte = int.bitwise_shift_right(header_byte, 4)
          let regenerated_size =
            int.bitwise_or(
              high_bits_of_header_byte,
              int.bitwise_or(
                int.bitwise_shift_left(b1, 4),
                int.bitwise_shift_left(int.bitwise_and(b2, 0x3), 12),
              ),
            )
          let compressed_size =
            int.bitwise_or(
              int.bitwise_shift_right(b2, 2),
              int.bitwise_shift_left(b3, 6),
            )
          Ok(CompressedLiteralsHeader(
            regenerated_size: regenerated_size,
            compressed_size: compressed_size,
            streams: 4,
            header_bytes: 4,
          ))
        }
        _ ->
          Error(error.CodecInvalidData(
            message: "truncated zstd compressed-literals 4-byte header",
          ))
      }
    _ ->
      // size_format = 3: 5-byte header, 4 streams, 18-bit fields.
      case bytes {
        <<_, b1, b2, b3, b4, _:bytes>> -> {
          let high_bits_of_header_byte = int.bitwise_shift_right(header_byte, 4)
          let regenerated_size =
            int.bitwise_or(
              high_bits_of_header_byte,
              int.bitwise_or(
                int.bitwise_shift_left(b1, 4),
                int.bitwise_shift_left(int.bitwise_and(b2, 0x3F), 12),
              ),
            )
          let compressed_size =
            int.bitwise_or(
              int.bitwise_shift_right(b2, 6),
              int.bitwise_or(
                int.bitwise_shift_left(b3, 2),
                int.bitwise_shift_left(b4, 10),
              ),
            )
          Ok(CompressedLiteralsHeader(
            regenerated_size: regenerated_size,
            compressed_size: compressed_size,
            streams: 4,
            header_bytes: 5,
          ))
        }
        _ ->
          Error(error.CodecInvalidData(
            message: "truncated zstd compressed-literals 5-byte header",
          ))
      }
  }
}

fn parse_raw_or_rle_literals(
  bytes: BitArray,
  header_byte: Int,
  size_format: Int,
  is_rle: Bool,
) -> Result(#(BitArray, BitArray), error.CodecError) {
  case size_format {
    0 | 2 -> {
      // 1-byte header — size is bits 3..7 of the header byte (5 bits).
      let regenerated_size = int.bitwise_shift_right(header_byte, 3)
      let assert Ok(after_header) =
        bit_array.slice(bytes, 1, bit_array.byte_size(bytes) - 1)
      finalize_literals(after_header, regenerated_size, is_rle)
    }
    1 -> {
      // 2-byte header — bits 4..7 of byte 0 + all of byte 1 (12 bits).
      case bytes {
        <<_h, b1, _:bytes>> -> {
          let regenerated_size =
            int.bitwise_or(
              int.bitwise_shift_right(header_byte, 4),
              int.bitwise_shift_left(b1, 4),
            )
          let assert Ok(after_header) =
            bit_array.slice(bytes, 2, bit_array.byte_size(bytes) - 2)
          finalize_literals(after_header, regenerated_size, is_rle)
        }
        _ ->
          Error(error.CodecInvalidData(
            message: "truncated zstd literals 2-byte header",
          ))
      }
    }
    _ -> {
      // size_format = 3: 3-byte header, 20-bit regen_size:
      //   bits 4..7 of byte 0 + all of byte 1 + all of byte 2.
      case bytes {
        <<_h, b1, b2, _:bytes>> -> {
          let regenerated_size =
            int.bitwise_or(
              int.bitwise_shift_right(header_byte, 4),
              int.bitwise_or(
                int.bitwise_shift_left(b1, 4),
                int.bitwise_shift_left(b2, 12),
              ),
            )
          let assert Ok(after_header) =
            bit_array.slice(bytes, 3, bit_array.byte_size(bytes) - 3)
          finalize_literals(after_header, regenerated_size, is_rle)
        }
        _ ->
          Error(error.CodecInvalidData(
            message: "truncated zstd literals 3-byte header",
          ))
      }
    }
  }
}

fn finalize_literals(
  bytes: BitArray,
  size: Int,
  is_rle: Bool,
) -> Result(#(BitArray, BitArray), error.CodecError) {
  case is_rle {
    True ->
      case bytes {
        <<byte, rest:bytes>> -> Ok(#(zstd_repeat_byte(byte, size, <<>>), rest))
        _ ->
          Error(error.CodecInvalidData(message: "truncated zstd RLE literals"))
      }
    False -> {
      use chunk <- result.try(slice_or_error(
        bytes,
        0,
        size,
        "zstd raw literals body",
      ))
      let assert Ok(rest) =
        bit_array.slice(bytes, size, bit_array.byte_size(bytes) - size)
      Ok(#(chunk, rest))
    }
  }
}

fn zstd_repeat_byte(byte: Int, count: Int, acc: BitArray) -> BitArray {
  case count {
    0 -> acc
    _ -> zstd_repeat_byte(byte, count - 1, <<acc:bits, byte>>)
  }
}

// -- sequences section + sequence application -------------------------

fn parse_and_apply_sequences(
  bytes: BitArray,
  literals: BitArray,
  prev_tables: SeqTablesState,
  previous_output_rev: List(Int),
  reps: #(Int, Int, Int),
) -> Result(#(BitArray, SeqTablesState, #(Int, Int, Int)), error.CodecError) {
  case bytes {
    <<>> -> Ok(#(literals, prev_tables, reps))
    <<num_byte, _:bytes>> if num_byte == 0 -> Ok(#(literals, prev_tables, reps))
    <<num_byte, _:bytes>> if num_byte < 128 ->
      parse_sequences(
        bytes,
        1,
        num_byte,
        literals,
        prev_tables,
        previous_output_rev,
        reps,
      )
    <<num_byte, b1, _:bytes>> if num_byte < 255 -> {
      let n = { num_byte - 128 } * 256 + b1
      parse_sequences(
        bytes,
        2,
        n,
        literals,
        prev_tables,
        previous_output_rev,
        reps,
      )
    }
    <<255, b1, b2, _:bytes>> -> {
      let n = b1 + b2 * 256 + 0x7F00
      parse_sequences(
        bytes,
        3,
        n,
        literals,
        prev_tables,
        previous_output_rev,
        reps,
      )
    }
    _ ->
      Error(error.CodecInvalidData(message: "truncated zstd sequences header"))
  }
}

fn parse_sequences(
  bytes: BitArray,
  count_size: Int,
  num_sequences: Int,
  literals: BitArray,
  prev_tables: SeqTablesState,
  previous_output_rev: List(Int),
  reps: #(Int, Int, Int),
) -> Result(#(BitArray, SeqTablesState, #(Int, Int, Int)), error.CodecError) {
  use after_count <- result.try(slice_after(
    bytes,
    count_size,
    "zstd sequences count",
  ))
  case after_count {
    <<modes, _:bytes>> -> {
      let literal_lengths_mode =
        int.bitwise_and(int.bitwise_shift_right(modes, 6), 0x3)
      let offsets_mode = int.bitwise_and(int.bitwise_shift_right(modes, 4), 0x3)
      let match_lengths_mode =
        int.bitwise_and(int.bitwise_shift_right(modes, 2), 0x3)
      let reserved = int.bitwise_and(modes, 0x3)
      use <- bool.guard(
        when: reserved != 0,
        return: Error(error.CodecInvalidData(
          message: "zstd sequences mode byte has reserved bits set",
        )),
      )
      use after_modes <- result.try(slice_after(
        after_count,
        1,
        "zstd sequences mode byte",
      ))
      use #(ll_table, ll_log, after_ll) <- result.try(load_sequence_table(
        after_modes,
        literal_lengths_mode,
        SeqAlphabetLl,
        prev_tables.ll,
      ))
      use #(of_table, of_log, after_of) <- result.try(load_sequence_table(
        after_ll,
        offsets_mode,
        SeqAlphabetOf,
        prev_tables.of,
      ))
      use #(ml_table, ml_log, bitstream) <- result.try(load_sequence_table(
        after_of,
        match_lengths_mode,
        SeqAlphabetMl,
        prev_tables.ml,
      ))
      use #(plain, new_reps) <- result.try(apply_sequences_with_tables(
        num_sequences,
        bitstream,
        literals,
        ll_table,
        ll_log,
        of_table,
        of_log,
        ml_table,
        ml_log,
        previous_output_rev,
        reps,
      ))
      Ok(#(
        plain,
        SeqTablesState(
          ll: Some(#(ll_table, ll_log)),
          of: Some(#(of_table, of_log)),
          ml: Some(#(ml_table, ml_log)),
        ),
        new_reps,
      ))
    }
    _ ->
      Error(error.CodecInvalidData(
        message: "truncated zstd sequences modes byte",
      ))
  }
}

/// Identifies which sequence alphabet a table description applies to.
/// Used to look up the correct predefined distribution, the maximum
/// allowed accuracy_log, and the maximum symbol value when parsing an
/// FSE_Compressed_Mode header.
type SeqAlphabet {
  SeqAlphabetLl
  SeqAlphabetOf
  SeqAlphabetMl
}

fn alphabet_max_log(alphabet: SeqAlphabet) -> Int {
  case alphabet {
    SeqAlphabetLl -> 9
    SeqAlphabetOf -> 8
    SeqAlphabetMl -> 9
  }
}

fn alphabet_max_symbol(alphabet: SeqAlphabet) -> Int {
  // The RFC 8478 sequence-symbol alphabets have upper bounds that
  // both bound the predefined distributions and cap any user-supplied
  // FSE distribution.
  case alphabet {
    SeqAlphabetLl -> 35
    SeqAlphabetOf -> 31
    SeqAlphabetMl -> 52
  }
}

fn predefined_for(
  alphabet: SeqAlphabet,
) -> #(dict.Dict(Int, fse.StateEntry), Int) {
  case alphabet {
    SeqAlphabetLl -> #(
      fse.predefined_literal_length_table(),
      fse.predefined_literal_length_log(),
    )
    SeqAlphabetOf -> #(
      fse.predefined_offset_table(),
      fse.predefined_offset_log(),
    )
    SeqAlphabetMl -> #(
      fse.predefined_match_length_table(),
      fse.predefined_match_length_log(),
    )
  }
}

fn alphabet_label(alphabet: SeqAlphabet) -> String {
  case alphabet {
    SeqAlphabetLl -> "literal_length"
    SeqAlphabetOf -> "offset"
    SeqAlphabetMl -> "match_length"
  }
}

/// Read the table description for one sequence alphabet, honouring the
/// Predefined / RLE / FSE_Compressed / Repeat selector encoded in the
/// modes byte.  Returns the materialised state table, its accuracy_log
/// (so the sequence decoder knows how many bits to read for the
/// initial state), and the byte slice that immediately follows the
/// table description.
fn load_sequence_table(
  bytes: BitArray,
  mode: Int,
  alphabet: SeqAlphabet,
  prev: Option(#(dict.Dict(Int, fse.StateEntry), Int)),
) -> Result(#(dict.Dict(Int, fse.StateEntry), Int, BitArray), error.CodecError) {
  case mode {
    0 -> {
      let #(table, accuracy_log) = predefined_for(alphabet)
      Ok(#(table, accuracy_log, bytes))
    }
    1 ->
      case bytes {
        <<symbol, rest:bytes>> -> {
          // RLE_Mode: the entire table maps state 0 to the single
          // symbol with zero baseline and zero nb_bits.  Accuracy_log
          // is 0 so the decoder reads no bits to seed the state.
          let table =
            dict.from_list([
              #(0, fse.StateEntry(symbol: symbol, nb_bits: 0, baseline: 0)),
            ])
          Ok(#(table, 0, rest))
        }
        _ ->
          Error(error.CodecInvalidData(
            message: "truncated zstd "
            <> alphabet_label(alphabet)
            <> " RLE mode symbol",
          ))
      }
    2 -> {
      use #(distribution, accuracy_log, rest) <- result.try(
        read_fse_distribution(
          bytes,
          alphabet_max_log(alphabet),
          alphabet_max_symbol(alphabet),
          alphabet_label(alphabet),
        ),
      )
      let table = fse.build_state_table(distribution, accuracy_log)
      Ok(#(table, accuracy_log, rest))
    }
    _ ->
      // Repeat_Mode: reuse the FSE table the previous block carried
      // for this alphabet.  RFC 8478 §3.1.1.4 forbids Repeat_Mode in
      // the first block of a frame, so an absent prior table is a
      // hard error.
      case prev {
        Some(#(table, accuracy_log)) -> Ok(#(table, accuracy_log, bytes))
        None ->
          Error(error.CodecInvalidData(
            message: "zstd "
            <> alphabet_label(alphabet)
            <> " Repeat_Mode without a prior FSE table",
          ))
      }
  }
}

fn apply_sequences_with_tables(
  num_sequences: Int,
  bitstream: BitArray,
  literals: BitArray,
  ll_table: dict.Dict(Int, fse.StateEntry),
  ll_log: Int,
  of_table: dict.Dict(Int, fse.StateEntry),
  of_log: Int,
  ml_table: dict.Dict(Int, fse.StateEntry),
  ml_log: Int,
  previous_output_rev: List(Int),
  reps: #(Int, Int, Int),
) -> Result(#(BitArray, #(Int, Int, Int)), error.CodecError) {
  case fse.new_backward_reader(bitstream) {
    Error(_) ->
      Error(error.CodecInvalidData(
        message: "zstd sequences bitstream is empty or missing marker",
      ))
    Ok(reader) -> {
      use #(ll_state, reader) <- result.try(read_state_init(
        reader,
        ll_log,
        "literal_length",
      ))
      use #(of_state, reader) <- result.try(read_state_init(
        reader,
        of_log,
        "offset",
      ))
      use #(ml_state, reader) <- result.try(read_state_init(
        reader,
        ml_log,
        "match_length",
      ))
      let prev_size = list.length(previous_output_rev)
      let #(rep0, rep1, rep2) = reps
      let ctx =
        SeqContext(
          literals: literals,
          literal_pos: 0,
          output_rev: previous_output_rev,
          output_prev_size: prev_size,
          rep0: rep0,
          rep1: rep1,
          rep2: rep2,
          ll_state: ll_state,
          of_state: of_state,
          ml_state: ml_state,
          ll_table: ll_table,
          of_table: of_table,
          ml_table: ml_table,
        )
      use ctx <- result.try(decode_sequence_loop(num_sequences, ctx, reader))
      Ok(#(append_remaining_literals(ctx), #(ctx.rep0, ctx.rep1, ctx.rep2)))
    }
  }
}

type SeqContext {
  SeqContext(
    literals: BitArray,
    literal_pos: Int,
    output_rev: List(Int),
    output_prev_size: Int,
    rep0: Int,
    rep1: Int,
    rep2: Int,
    ll_state: Int,
    of_state: Int,
    ml_state: Int,
    ll_table: dict.Dict(Int, fse.StateEntry),
    of_table: dict.Dict(Int, fse.StateEntry),
    ml_table: dict.Dict(Int, fse.StateEntry),
  )
}

// -- FSE distribution decoder (RFC 8478 §4.1.1.2) ----------------------
//
// The distribution header is a forward-read bit stream encoded LSB-
// first inside its enclosing byte sequence.  The first 4 bits hold
// `Accuracy_Log - 5`; subsequent counts come from a variable-bit
// state-machine that adjusts its read width as the running total
// approaches the target table size.  Zero counts trigger a 2-bit RLE
// jump until a < 3 group terminates the run.  Once the distribution
// is exhausted the encoder pads the remaining bits in the trailing
// byte; the FSE sequences bitstream resumes at the next byte boundary.

type FwdBitReader {
  FwdBitReader(
    source: BitArray,
    buffer: Int,
    bits: Int,
    overflow: Bool,
    bits_consumed: Int,
  )
}

fn new_fwd_reader(bytes: BitArray) -> FwdBitReader {
  FwdBitReader(
    source: bytes,
    buffer: 0,
    bits: 0,
    overflow: False,
    bits_consumed: 0,
  )
}

fn fwd_refill(reader: FwdBitReader, needed: Int) -> FwdBitReader {
  case reader.bits >= needed || reader.overflow {
    True -> reader
    False ->
      case reader.source {
        <<b, rest:bytes>> ->
          fwd_refill(
            FwdBitReader(
              source: rest,
              buffer: int.bitwise_or(
                reader.buffer,
                int.bitwise_shift_left(b, reader.bits),
              ),
              bits: reader.bits + 8,
              overflow: False,
              bits_consumed: reader.bits_consumed,
            ),
            needed,
          )
        _ -> FwdBitReader(..reader, overflow: True)
      }
  }
}

fn fwd_peek(reader: FwdBitReader, count: Int) -> #(Int, FwdBitReader) {
  let reader = fwd_refill(reader, count)
  let mask = int.bitwise_shift_left(1, count) - 1
  #(int.bitwise_and(reader.buffer, mask), reader)
}

fn fwd_drop(reader: FwdBitReader, count: Int) -> FwdBitReader {
  let reader = fwd_refill(reader, count)
  FwdBitReader(
    source: reader.source,
    buffer: int.bitwise_shift_right(reader.buffer, count),
    bits: reader.bits - count,
    overflow: reader.overflow,
    bits_consumed: reader.bits_consumed + count,
  )
}

fn fwd_read(
  reader: FwdBitReader,
  count: Int,
  label: String,
) -> Result(#(Int, FwdBitReader), error.CodecError) {
  let reader = fwd_refill(reader, count)
  case reader.bits < count {
    True -> Error(error.CodecInvalidData(message: "truncated zstd " <> label))
    False -> {
      let #(value, reader) = fwd_peek(reader, count)
      Ok(#(value, fwd_drop(reader, count)))
    }
  }
}

fn read_fse_distribution(
  bytes: BitArray,
  max_accuracy_log: Int,
  max_symbol: Int,
  label: String,
) -> Result(#(List(Int), Int, BitArray), error.CodecError) {
  let reader = new_fwd_reader(bytes)
  use #(accuracy_minus_5, reader) <- result.try(fwd_read(
    reader,
    4,
    label <> " distribution accuracy_log",
  ))
  let accuracy_log = accuracy_minus_5 + 5
  use <- bool.guard(
    when: accuracy_log > max_accuracy_log,
    return: Error(error.CodecInvalidData(
      message: "zstd "
      <> label
      <> " FSE accuracy_log exceeds the alphabet's maximum",
    )),
  )
  let table_size = int.bitwise_shift_left(1, accuracy_log)
  use #(counts, reader) <- result.try(decode_fse_distribution(
    reader,
    accuracy_log,
    table_size + 1,
    table_size,
    accuracy_log + 1,
    False,
    0,
    max_symbol,
    [],
    label,
  ))
  // The trailing bits inside the current byte are padding; the next
  // byte starts the section after the table description.
  let bytes_consumed = { reader.bits_consumed + 7 } / 8
  let total = bit_array.byte_size(bytes)
  case bit_array.slice(bytes, bytes_consumed, total - bytes_consumed) {
    Ok(rest) ->
      Ok(#(pad_distribution(counts, max_symbol + 1), accuracy_log, rest))
    Error(_) ->
      Error(error.CodecInvalidData(
        message: "truncated zstd " <> label <> " FSE distribution tail",
      ))
  }
}

fn decode_fse_distribution(
  reader: FwdBitReader,
  _accuracy_log: Int,
  remaining: Int,
  threshold: Int,
  bit_count: Int,
  previous_is_zero: Bool,
  charnum: Int,
  max_symbol: Int,
  acc: List(Int),
  label: String,
) -> Result(#(List(Int), FwdBitReader), error.CodecError) {
  case remaining > 1 && charnum <= max_symbol {
    False -> Ok(#(list.reverse(acc), reader))
    True ->
      case previous_is_zero {
        True -> {
          use #(extra, reader) <- result.try(read_zero_rle(reader, label))
          let acc = prepend_zeros(extra, acc)
          decode_fse_distribution(
            reader,
            0,
            remaining,
            threshold,
            bit_count,
            False,
            charnum + extra,
            max_symbol,
            acc,
            label,
          )
        }
        False -> {
          let #(value, reader) = fwd_peek(reader, bit_count)
          let #(count, bits_consumed) =
            decode_count_bits(value, threshold, remaining, bit_count)
          let reader = fwd_drop(reader, bits_consumed)
          let probability = count - 1
          let abs_prob = case probability < 0 {
            True -> -probability
            False -> probability
          }
          let remaining = remaining - abs_prob
          let previous_is_zero = probability == 0
          let #(threshold, bit_count) =
            shrink_threshold(threshold, bit_count, remaining)
          decode_fse_distribution(
            reader,
            0,
            remaining,
            threshold,
            bit_count,
            previous_is_zero,
            charnum + 1,
            max_symbol,
            [probability, ..acc],
            label,
          )
        }
      }
  }
}

/// Split out of `decode_fse_distribution` so the dominant case (short
/// form) doesn't dominate the inner block's indentation budget.
fn decode_count_bits(
  value: Int,
  threshold: Int,
  remaining: Int,
  bit_count: Int,
) -> #(Int, Int) {
  let max_val = 2 * threshold - 1 - remaining
  case int.bitwise_and(value, threshold - 1) < max_val {
    True -> #(int.bitwise_and(value, threshold - 1), bit_count - 1)
    False -> {
      let raw = int.bitwise_and(value, 2 * threshold - 1)
      let adjusted = case raw >= threshold {
        True -> raw - max_val
        False -> raw
      }
      #(adjusted, bit_count)
    }
  }
}

fn read_zero_rle(
  reader: FwdBitReader,
  label: String,
) -> Result(#(Int, FwdBitReader), error.CodecError) {
  read_zero_rle_loop(reader, 0, label)
}

fn read_zero_rle_loop(
  reader: FwdBitReader,
  acc: Int,
  label: String,
) -> Result(#(Int, FwdBitReader), error.CodecError) {
  use #(value, reader) <- result.try(fwd_read(
    reader,
    2,
    label <> " FSE distribution zero-RLE flag",
  ))
  case value {
    3 -> read_zero_rle_loop(reader, acc + 3, label)
    n -> Ok(#(acc + n, reader))
  }
}

fn shrink_threshold(
  threshold: Int,
  bit_count: Int,
  remaining: Int,
) -> #(Int, Int) {
  case remaining < threshold {
    True -> shrink_threshold(threshold / 2, bit_count - 1, remaining)
    False -> #(threshold, bit_count)
  }
}

fn prepend_zeros(count: Int, acc: List(Int)) -> List(Int) {
  case count {
    n if n <= 0 -> acc
    _ -> prepend_zeros(count - 1, [0, ..acc])
  }
}

fn pad_distribution(counts: List(Int), target: Int) -> List(Int) {
  let current = list.length(counts)
  case current >= target {
    True -> counts
    False -> list.append(counts, list.repeat(0, target - current))
  }
}

fn read_state_init(
  reader: fse.BackwardReader,
  bits: Int,
  label: String,
) -> Result(#(Int, fse.BackwardReader), error.CodecError) {
  case fse.read_backward_bits(reader, bits) {
    Ok(#(v, r)) -> Ok(#(v, r))
    Error(_) ->
      Error(error.CodecInvalidData(
        message: "truncated zstd " <> label <> " initial state",
      ))
  }
}

fn decode_sequence_loop(
  remaining: Int,
  ctx: SeqContext,
  reader: fse.BackwardReader,
) -> Result(SeqContext, error.CodecError) {
  case remaining {
    0 -> Ok(ctx)
    _ -> {
      let ll_code = state_symbol(ctx.ll_table, ctx.ll_state)
      let of_code = state_symbol(ctx.of_table, ctx.of_state)
      let ml_code = state_symbol(ctx.ml_table, ctx.ml_state)

      use #(offset_value, reader) <- result.try(read_bits_for(
        reader,
        of_code,
        "offset extra",
      ))
      use #(match_extra, reader) <- result.try(read_bits_for(
        reader,
        fse.ml_extra_bits(ml_code),
        "match-length extra",
      ))
      use #(lit_extra, reader) <- result.try(read_bits_for(
        reader,
        fse.ll_extra_bits(ll_code),
        "literal-length extra",
      ))

      let literal_length = fse.ll_base(ll_code) + lit_extra
      let match_length = fse.ml_base(ml_code) + match_extra
      let raw_offset = int.bitwise_shift_left(1, of_code) + offset_value
      let #(actual_offset, ctx_after_offset) =
        resolve_offset(ctx, of_code, raw_offset, literal_length)

      // Copy literals and match into output_rev.
      use ctx_after_lit <- result.try(copy_literals(
        ctx_after_offset,
        literal_length,
      ))
      use ctx_after_match <- result.try(copy_match(
        ctx_after_lit,
        actual_offset,
        match_length,
      ))

      // Update states if not the last sequence.
      case remaining {
        1 -> Ok(ctx_after_match)
        _ -> {
          use #(reader, ll_state) <- result.try(update_state(
            reader,
            ctx.ll_table,
            ctx.ll_state,
            "literal_length",
          ))
          use #(reader, ml_state) <- result.try(update_state(
            reader,
            ctx.ml_table,
            ctx.ml_state,
            "match_length",
          ))
          use #(reader, of_state) <- result.try(update_state(
            reader,
            ctx.of_table,
            ctx.of_state,
            "offset",
          ))
          decode_sequence_loop(
            remaining - 1,
            SeqContext(
              ..ctx_after_match,
              ll_state: ll_state,
              ml_state: ml_state,
              of_state: of_state,
            ),
            reader,
          )
        }
      }
    }
  }
}

fn state_symbol(table: dict.Dict(Int, fse.StateEntry), state: Int) -> Int {
  case dict.get(table, state) {
    Ok(entry) -> entry.symbol
    Error(_) -> 0
  }
}

fn update_state(
  reader: fse.BackwardReader,
  table: dict.Dict(Int, fse.StateEntry),
  state: Int,
  label: String,
) -> Result(#(fse.BackwardReader, Int), error.CodecError) {
  let entry = case dict.get(table, state) {
    Ok(e) -> e
    Error(_) -> fse.StateEntry(symbol: 0, nb_bits: 0, baseline: 0)
  }
  case fse.read_backward_bits(reader, entry.nb_bits) {
    Ok(#(extra, r)) -> Ok(#(r, entry.baseline + extra))
    Error(_) ->
      Error(error.CodecInvalidData(
        message: "truncated zstd " <> label <> " state-update bits",
      ))
  }
}

fn read_bits_for(
  reader: fse.BackwardReader,
  count: Int,
  label: String,
) -> Result(#(Int, fse.BackwardReader), error.CodecError) {
  case fse.read_backward_bits(reader, count) {
    Ok(p) -> Ok(p)
    Error(_) ->
      Error(error.CodecInvalidData(message: "truncated zstd " <> label))
  }
}

fn resolve_offset(
  ctx: SeqContext,
  _of_code: Int,
  raw_offset: Int,
  literal_length: Int,
) -> #(Int, SeqContext) {
  // RFC 8478 §3.1.1.5 dispatches on the offset *value* (called
  // `raw_offset` here, equal to `(1 << of_code) + extra`), NOT on
  // the FSE-decoded of_code itself.  An earlier revision keyed on
  // of_code, which silently clamped raw_offset values of 2 and 3
  // (of_code == 1) into "use rep[0]" and produced wrong matches.
  case raw_offset {
    1 ->
      case literal_length {
        0 -> {
          // LL == 0: offset_value 1 means repeated_offset[1] (and
          // the rep history shifts accordingly).
          let actual = ctx.rep1
          #(actual, SeqContext(..ctx, rep0: ctx.rep1, rep1: ctx.rep0))
        }
        _ -> {
          // LL > 0: repeated_offset[0], history unchanged.
          #(ctx.rep0, ctx)
        }
      }
    2 ->
      case literal_length {
        0 -> {
          // LL == 0, offset_value 2 ⇒ repCode 2 (see
          // ZSTD_updateRep): rep[2] = rep[1], rep[1] = rep[0],
          // rep[0] = old rep[2].  IMPORTANT: read all three fields
          // off `ctx` BEFORE constructing the new record (a chained
          // update inside one SeqContext literal would otherwise
          // observe its own freshly-written fields and corrupt the
          // history).
          let actual = ctx.rep2
          #(
            actual,
            SeqContext(..ctx, rep2: ctx.rep1, rep1: ctx.rep0, rep0: actual),
          )
        }
        _ -> {
          // LL > 0, offset_value 2 ⇒ repCode 1: rep[1] = rep[0],
          // rep[0] = old rep[1].  rep[2] is unchanged.
          let actual = ctx.rep1
          #(actual, SeqContext(..ctx, rep0: ctx.rep1, rep1: ctx.rep0))
        }
      }
    3 ->
      case literal_length {
        0 -> {
          // LL == 0: offset_value 3 means repeated_offset[0] - 1.
          let actual = case ctx.rep0 - 1 {
            n if n <= 0 -> 1
            n -> n
          }
          #(
            actual,
            SeqContext(..ctx, rep2: ctx.rep1, rep1: ctx.rep0, rep0: actual),
          )
        }
        _ -> {
          // LL > 0: offset_value 3 means repeated_offset[2].
          let actual = ctx.rep2
          #(
            actual,
            SeqContext(..ctx, rep2: ctx.rep1, rep1: ctx.rep0, rep0: actual),
          )
        }
      }
    _ -> {
      // raw_offset > 3: a normal (non-repeated) offset.
      let actual = raw_offset - 3
      #(actual, SeqContext(..ctx, rep2: ctx.rep1, rep1: ctx.rep0, rep0: actual))
    }
  }
}

fn copy_literals(
  ctx: SeqContext,
  count: Int,
) -> Result(SeqContext, error.CodecError) {
  case count {
    0 -> Ok(ctx)
    _ -> {
      case bit_array.slice(ctx.literals, ctx.literal_pos, count) {
        Ok(chunk) ->
          Ok(
            SeqContext(
              ..ctx,
              literal_pos: ctx.literal_pos + count,
              output_rev: prepend_bytes(chunk, ctx.output_rev),
            ),
          )
        Error(_) ->
          Error(error.CodecInvalidData(
            message: "zstd literal copy exceeds literals section",
          ))
      }
    }
  }
}

fn copy_match(
  ctx: SeqContext,
  offset: Int,
  length: Int,
) -> Result(SeqContext, error.CodecError) {
  copy_match_loop(ctx, offset, length)
}

fn copy_match_loop(
  ctx: SeqContext,
  offset: Int,
  remaining: Int,
) -> Result(SeqContext, error.CodecError) {
  case remaining {
    0 -> Ok(ctx)
    _ -> {
      case nth_from_back(ctx.output_rev, offset - 1) {
        Ok(byte) ->
          copy_match_loop(
            SeqContext(..ctx, output_rev: [byte, ..ctx.output_rev]),
            offset,
            remaining - 1,
          )
        Error(_) ->
          Error(error.CodecInvalidData(
            message: "zstd match offset exceeds emitted output",
          ))
      }
    }
  }
}

fn nth_from_back(values: List(Int), n: Int) -> Result(Int, Nil) {
  case values, n {
    [head, ..], 0 -> Ok(head)
    [_, ..rest], _ -> nth_from_back(rest, n - 1)
    [], _ -> Error(Nil)
  }
}

fn prepend_bytes(chunk: BitArray, acc: List(Int)) -> List(Int) {
  case chunk {
    <<b, rest:bytes>> -> prepend_bytes(rest, [b, ..acc])
    _ -> acc
  }
}

fn append_remaining_literals(ctx: SeqContext) -> BitArray {
  let remaining = bit_array.byte_size(ctx.literals) - ctx.literal_pos
  let assert Ok(tail) =
    bit_array.slice(ctx.literals, ctx.literal_pos, remaining)
  // ctx.output_rev now contains the previous blocks' bytes plus
  // this block's bytes (most-recent first).  Trim the tail bytes
  // that belong to previous blocks so we return only this block's
  // payload.
  let this_block_rev = list_drop_tail(ctx.output_rev, ctx.output_prev_size)
  let prefix = reverse_list_to_bit_array(this_block_rev, <<>>)
  bit_array.concat([prefix, tail])
}

/// Drop the `n` trailing elements from a list.  Used to strip the
/// previous-blocks suffix off the running output buffer so only the
/// current block's payload is returned.
fn list_drop_tail(items: List(Int), n: Int) -> List(Int) {
  let total = list.length(items)
  case total - n {
    keep if keep <= 0 -> []
    keep -> list.take(items, keep)
  }
}

fn reverse_list_to_bit_array(values: List(Int), acc: BitArray) -> BitArray {
  case values {
    [] -> acc
    [head, ..rest] -> reverse_list_to_bit_array(rest, <<head, acc:bits>>)
  }
}

fn slice_or_error(
  bytes: BitArray,
  offset: Int,
  length: Int,
  label: String,
) -> Result(BitArray, error.CodecError) {
  case bit_array.slice(bytes, offset, length) {
    Ok(v) -> Ok(v)
    Error(_) -> Error(error.CodecInvalidData(message: "truncated " <> label))
  }
}

fn slice_after(
  bytes: BitArray,
  offset: Int,
  label: String,
) -> Result(BitArray, error.CodecError) {
  case bit_array.slice(bytes, offset, bit_array.byte_size(bytes) - offset) {
    Ok(v) -> Ok(v)
    Error(_) -> Error(error.CodecInvalidData(message: "truncated " <> label))
  }
}

fn decode_raw_block(
  bytes: BitArray,
  block_size: Int,
) -> Result(#(BitArray, BitArray), error.CodecError) {
  case bit_array.slice(bytes, 0, block_size) {
    Ok(chunk) ->
      case
        bit_array.slice(
          bytes,
          block_size,
          bit_array.byte_size(bytes) - block_size,
        )
      {
        Ok(rest) -> Ok(#(chunk, rest))
        Error(_) ->
          Error(error.CodecInvalidData(message: "truncated zstd raw block tail"))
      }
    Error(_) ->
      Error(error.CodecInvalidData(message: "truncated zstd raw block"))
  }
}

fn decode_rle_block(
  bytes: BitArray,
  block_size: Int,
) -> Result(#(BitArray, BitArray), error.CodecError) {
  case bytes {
    <<byte, rest:bytes>> -> Ok(#(repeat_byte(byte, block_size, <<>>), rest))
    _ -> Error(error.CodecInvalidData(message: "truncated zstd RLE block"))
  }
}

fn repeat_byte(byte: Int, count: Int, acc: BitArray) -> BitArray {
  case count {
    0 -> acc
    _ -> repeat_byte(byte, count - 1, <<acc:bits, byte>>)
  }
}

// -- helpers -----------------------------------------------------------

fn drop_bytes(
  bytes: BitArray,
  count: Int,
  label: String,
) -> Result(BitArray, error.CodecError) {
  case count {
    0 -> Ok(bytes)
    _ ->
      case bit_array.slice(bytes, count, bit_array.byte_size(bytes) - count) {
        Ok(rest) -> Ok(rest)
        Error(_) ->
          Error(error.CodecInvalidData(message: "truncated " <> label))
      }
  }
}

fn append_with_limit(
  output: BitArray,
  chunk: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  let projected = bit_array.byte_size(output) + bit_array.byte_size(chunk)
  case projected > limit.max_output_bytes(limits) {
    True ->
      Error(error.CodecLimitExceeded(
        limit: "max_output_bytes",
        actual: projected,
      ))
    False -> Ok(bit_array.concat([output, chunk]))
  }
}
