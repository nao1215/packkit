//// bzip2 codec — pure Gleam decoder for `.bz2` streams.
////
//// The decoder consumes the `"BZh"` magic, a single-character
//// block-size label (1..9), one or more compressed blocks, and the
//// stream end-marker plus 32-bit combined CRC.  Each block is
//// reversed through Huffman decoding, MTF inversion, inverse
//// Burrows-Wheeler, and the RLE1 expansion that bzip2 applies to the
//// raw input before transformation.  The encoder is intentionally
//// deferred.

import gleam/bit_array
import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/order
import gleam/result
import packkit/checksum
import packkit/codec as codecs
import packkit/error
import packkit/limit

const block_magic_high: Int = 0x314159

const block_magic_low: Int = 0x265359

const eos_magic_high: Int = 0x177245

const eos_magic_low: Int = 0x385090

const max_code_length: Int = 20

const max_selectors: Int = 18_002

const group_size: Int = 50

/// bzip2 codec smart constructor.
pub fn codec() -> codecs.Codec {
  codecs.bzip2()
}

/// Encode `bytes` as a bzip2 stream using the default block size 9
/// (900 KiB).  The encoder emits a single block plus the stream
/// trailer with the combined CRC; large inputs that exceed the
/// block size will still be packed into one block, so a naive
/// forward BWT may dominate the running time.
pub fn encode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  encode_with_level(bytes: bytes, level: 9)
}

/// Encode `bytes` as a bzip2 stream with an explicit block-size
/// level (1..9).  The level only affects the stream header byte; the
/// encoder always emits a single block so the level mostly carries
/// over for round-trip tooling.
pub fn encode_with_level(
  bytes bytes: BitArray,
  level level: Int,
) -> Result(BitArray, error.CodecError) {
  use <- bool.guard(
    when: level < 1 || level > 9,
    return: Error(error.CodecInvalidData(message: "bzip2 level must be in 1..9")),
  )
  let level_byte = 0x30 + level
  let header = <<0x42, 0x5A, 0x68, level_byte>>
  case bit_array.byte_size(bytes) {
    0 -> {
      let writer = write_eos_marker(new_writer(), 0)
      Ok(bit_array.concat([header, flush_writer_msb(writer)]))
    }
    _ -> {
      let stream_crc = checksum.bzip2_crc32(bytes)
      let writer = encode_block(new_writer(), bytes)
      let writer = write_eos_marker(writer, stream_crc)
      Ok(bit_array.concat([header, flush_writer_msb(writer)]))
    }
  }
}

fn write_eos_marker(writer: Writer, stream_crc: Int) -> Writer {
  writer
  |> write_bits_msb(eos_magic_high, 24)
  |> write_bits_msb(eos_magic_low, 24)
  |> write_bits_msb(stream_crc, 32)
}

/// Decode a bzip2 stream using the shared default `Limits`.
pub fn decode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  decode_with_limits(bytes: bytes, limits: limit.default())
}

/// Decode a bzip2 stream using explicit `Limits`.
///
/// Handles multi-stream `.bz2` files (the `bzcat`-style concatenation
/// of independent bzip2 streams).  When the end-of-stream marker for
/// one stream is reached, the decoder aligns to the next byte
/// boundary and looks for another `"BZh"` magic; if present, the
/// next stream's payload is appended to the accumulated output.
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

  decode_streams_loop(bytes, <<>>, 0, limits)
}

fn decode_streams_loop(
  bytes: BitArray,
  acc: BitArray,
  accumulated_size: Int,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  use rest <- result.try(parse_stream_header(bytes))
  use #(payload, after) <- result.try(decode_blocks_with_remainder(
    new_reader(rest),
    <<>>,
    0,
    limits,
  ))
  let next_size = accumulated_size + bit_array.byte_size(payload)
  case next_size > limit.max_output_bytes(limits) {
    True ->
      Error(error.CodecLimitExceeded(
        limit: "max_output_bytes",
        actual: next_size,
      ))
    False -> {
      let acc = bit_array.concat([acc, payload])
      case bit_array.byte_size(after) {
        0 -> Ok(acc)
        _ -> decode_streams_loop(after, acc, next_size, limits)
      }
    }
  }
}

// -- stream header -------------------------------------------------------

fn parse_stream_header(bytes: BitArray) -> Result(BitArray, error.CodecError) {
  case bytes {
    <<0x42, 0x5A, 0x68, level, rest:bytes>> if level >= 0x31 && level <= 0x39 ->
      Ok(rest)
    _ -> Error(error.CodecInvalidData(message: "invalid bzip2 stream header"))
  }
}

// -- block driver --------------------------------------------------------

fn decode_blocks_with_remainder(
  reader: Reader,
  output: BitArray,
  combined_crc: Int,
  limits: limit.Limits,
) -> Result(#(BitArray, BitArray), error.CodecError) {
  use #(magic_high, reader) <- result.try(read_bits(reader, 24))
  use #(magic_low, reader) <- result.try(read_bits(reader, 24))

  case magic_high, magic_low {
    h, l if h == block_magic_high && l == block_magic_low -> {
      use #(block_bytes, block_crc, reader) <- result.try(decode_block(
        reader,
        limits,
      ))
      use _ <- result.try(verify_block_crc(block_bytes, block_crc))
      let combined_crc = combine_block_crc(combined_crc, block_crc)
      use new_output <- result.try(append_with_limit(
        output,
        block_bytes,
        limits,
      ))
      decode_blocks_with_remainder(reader, new_output, combined_crc, limits)
    }
    h, l if h == eos_magic_high && l == eos_magic_low -> {
      use #(stream_crc, reader) <- result.try(read_bits(reader, 32))
      case stream_crc == combined_crc {
        True -> Ok(#(output, byte_aligned_remainder(reader)))
        False ->
          Error(error.CodecInvalidData(message: "bzip2 stream CRC mismatch"))
      }
    }
    _, _ ->
      Error(error.CodecInvalidData(message: "unexpected bzip2 block marker"))
  }
}

/// Recover the byte-aligned tail of the bit reader so the caller can
/// look for another stream's `"BZh"` magic.  bzip2 streams pad to
/// the next byte boundary after the stream CRC, so any partial bits
/// still sitting in `reader.buffer` are padding and we discard them.
fn byte_aligned_remainder(reader: Reader) -> BitArray {
  let _ = reader.buffer
  reader.source
}

fn combine_block_crc(combined: Int, block_crc: Int) -> Int {
  let rotated =
    int.bitwise_or(
      int.bitwise_and(int.bitwise_shift_left(combined, 1), 0xFFFFFFFF),
      int.bitwise_shift_right(combined, 31),
    )
  int.bitwise_and(int.bitwise_exclusive_or(rotated, block_crc), 0xFFFFFFFF)
}

fn verify_block_crc(
  data: BitArray,
  expected: Int,
) -> Result(Nil, error.CodecError) {
  case checksum.bzip2_crc32(data) == expected {
    True -> Ok(Nil)
    False -> Error(error.CodecInvalidData(message: "bzip2 block CRC mismatch"))
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

// -- single block --------------------------------------------------------

fn decode_block(
  reader: Reader,
  limits: limit.Limits,
) -> Result(#(BitArray, Int, Reader), error.CodecError) {
  use #(crc, reader) <- result.try(read_bits(reader, 32))
  use #(randomized, reader) <- result.try(read_bits(reader, 1))
  use <- bool.guard(
    when: randomized != 0,
    return: Error(error.CodecInvalidData(
      message: "randomized bzip2 blocks are not supported",
    )),
  )
  use #(orig_ptr, reader) <- result.try(read_bits(reader, 24))

  use #(symbols, reader) <- result.try(read_symbol_map(reader))
  let num_syms = list.length(symbols)
  use <- bool.guard(
    when: num_syms == 0,
    return: Error(error.CodecInvalidData(message: "empty bzip2 symbol map")),
  )
  let alphabet_size = num_syms + 2

  use #(num_tables, reader) <- result.try(read_bits(reader, 3))
  use <- bool.guard(
    when: num_tables < 2 || num_tables > 6,
    return: Error(error.CodecInvalidData(
      message: "invalid bzip2 huffman table count",
    )),
  )

  use #(num_selectors, reader) <- result.try(read_bits(reader, 15))
  use <- bool.guard(
    when: num_selectors <= 0 || num_selectors > max_selectors,
    return: Error(error.CodecInvalidData(
      message: "invalid bzip2 selector count",
    )),
  )

  use #(selectors, reader) <- result.try(read_selectors(
    reader,
    num_selectors,
    num_tables,
  ))
  use #(tables, reader) <- result.try(read_huffman_tables(
    reader,
    num_tables,
    alphabet_size,
  ))

  let tables_arr = list_to_dict(tables, 0, dict.new())
  let selectors_arr = list_to_dict(selectors, 0, dict.new())
  let eob = alphabet_size - 1

  use #(l_string, l_len, reader) <- result.try(decode_huffman_stream(
    reader,
    tables_arr,
    selectors_arr,
    eob,
    symbols,
    num_syms,
    0,
    0,
    1,
    [],
    0,
    limits,
  ))

  use <- bool.guard(
    when: orig_ptr >= l_len,
    return: Error(error.CodecInvalidData(
      message: "bzip2 BWT origin out of range",
    )),
  )

  let bwt_dict = inverse_bwt(l_string, l_len, orig_ptr)
  let plain = rle1_decode(bwt_dict, l_len)

  Ok(#(plain, crc, reader))
}

// -- symbol map ----------------------------------------------------------

fn read_symbol_map(
  reader: Reader,
) -> Result(#(List(Int), Reader), error.CodecError) {
  use #(present_groups, reader) <- result.try(read_bits(reader, 16))
  read_symbol_groups(reader, present_groups, 0, [])
}

fn read_symbol_groups(
  reader: Reader,
  presence: Int,
  group: Int,
  acc: List(Int),
) -> Result(#(List(Int), Reader), error.CodecError) {
  case group >= 16 {
    True -> Ok(#(list.reverse(acc), reader))
    False -> {
      let bit_mask = int.bitwise_shift_left(1, 15 - group)
      case int.bitwise_and(presence, bit_mask) {
        0 -> read_symbol_groups(reader, presence, group + 1, acc)
        _ -> {
          use #(bits, reader) <- result.try(read_bits(reader, 16))
          let acc = collect_group_bytes(bits, group, 0, acc)
          read_symbol_groups(reader, presence, group + 1, acc)
        }
      }
    }
  }
}

fn collect_group_bytes(
  bits: Int,
  group: Int,
  offset: Int,
  acc: List(Int),
) -> List(Int) {
  case offset >= 16 {
    True -> acc
    False -> {
      let mask = int.bitwise_shift_left(1, 15 - offset)
      let acc = case int.bitwise_and(bits, mask) {
        0 -> acc
        _ -> [group * 16 + offset, ..acc]
      }
      collect_group_bytes(bits, group, offset + 1, acc)
    }
  }
}

// -- selectors -----------------------------------------------------------

fn read_selectors(
  reader: Reader,
  remaining: Int,
  num_tables: Int,
) -> Result(#(List(Int), Reader), error.CodecError) {
  let stack = init_selector_stack(num_tables, 0, [])
  read_selectors_loop(reader, remaining, stack, [])
}

fn init_selector_stack(num: Int, index: Int, acc: List(Int)) -> List(Int) {
  case index >= num {
    True -> list.reverse(acc)
    False -> init_selector_stack(num, index + 1, [index, ..acc])
  }
}

fn read_selectors_loop(
  reader: Reader,
  remaining: Int,
  stack: List(Int),
  acc: List(Int),
) -> Result(#(List(Int), Reader), error.CodecError) {
  case remaining {
    0 -> Ok(#(list.reverse(acc), reader))
    _ -> {
      use #(index, reader) <- result.try(read_unary(reader, 0))
      use <- bool.guard(
        when: index >= list.length(stack),
        return: Error(error.CodecInvalidData(
          message: "bzip2 selector out of range",
        )),
      )
      let #(picked, remaining_stack) = pick_at(stack, index, [])
      let stack = [picked, ..remaining_stack]
      read_selectors_loop(reader, remaining - 1, stack, [picked, ..acc])
    }
  }
}

fn read_unary(
  reader: Reader,
  acc: Int,
) -> Result(#(Int, Reader), error.CodecError) {
  use #(bit, reader) <- result.try(read_bits(reader, 1))
  case bit {
    0 -> Ok(#(acc, reader))
    _ -> read_unary(reader, acc + 1)
  }
}

fn pick_at(stack: List(Int), index: Int, prefix: List(Int)) -> #(Int, List(Int)) {
  case stack, index {
    [head, ..rest], 0 -> #(head, list.append(list.reverse(prefix), rest))
    [head, ..rest], _ -> pick_at(rest, index - 1, [head, ..prefix])
    [], _ -> #(0, list.reverse(prefix))
  }
}

// -- huffman tables ------------------------------------------------------

type HuffmanTable {
  HuffmanTable(
    min_length: Int,
    max_length: Int,
    base: dict.Dict(Int, Int),
    limit: dict.Dict(Int, Int),
    symbols: dict.Dict(Int, Int),
  )
}

fn read_huffman_tables(
  reader: Reader,
  count: Int,
  alphabet_size: Int,
) -> Result(#(List(HuffmanTable), Reader), error.CodecError) {
  read_huffman_tables_loop(reader, count, alphabet_size, [])
}

fn read_huffman_tables_loop(
  reader: Reader,
  remaining: Int,
  alphabet_size: Int,
  acc: List(HuffmanTable),
) -> Result(#(List(HuffmanTable), Reader), error.CodecError) {
  case remaining {
    0 -> Ok(#(list.reverse(acc), reader))
    _ -> {
      use #(initial, reader) <- result.try(read_bits(reader, 5))
      use #(lengths, reader) <- result.try(
        read_table_lengths(reader, alphabet_size, initial, []),
      )
      use table <- result.try(build_huffman_table(lengths))
      read_huffman_tables_loop(reader, remaining - 1, alphabet_size, [
        table,
        ..acc
      ])
    }
  }
}

fn read_table_lengths(
  reader: Reader,
  remaining: Int,
  current: Int,
  acc: List(Int),
) -> Result(#(List(Int), Reader), error.CodecError) {
  case remaining {
    0 -> Ok(#(list.reverse(acc), reader))
    _ -> {
      use #(current, reader) <- result.try(adjust_length(reader, current))
      use <- bool.guard(
        when: current < 1 || current > max_code_length,
        return: Error(error.CodecInvalidData(
          message: "bzip2 huffman length out of range",
        )),
      )
      read_table_lengths(reader, remaining - 1, current, [current, ..acc])
    }
  }
}

fn adjust_length(
  reader: Reader,
  current: Int,
) -> Result(#(Int, Reader), error.CodecError) {
  use #(flag, reader) <- result.try(read_bits(reader, 1))
  case flag {
    0 -> Ok(#(current, reader))
    _ -> {
      use #(direction, reader) <- result.try(read_bits(reader, 1))
      let updated = case direction {
        0 -> current + 1
        _ -> current - 1
      }
      adjust_length(reader, updated)
    }
  }
}

fn build_huffman_table(
  lengths: List(Int),
) -> Result(HuffmanTable, error.CodecError) {
  let pairs = enumerate_lengths(lengths, 0, [])
  let min_length = find_min_length(lengths, 21)
  let max_length = find_max_length(lengths, 0)
  use <- bool.guard(
    when: min_length < 1 || max_length > max_code_length || max_length < 1,
    return: Error(error.CodecInvalidData(
      message: "bzip2 huffman length out of range",
    )),
  )
  let sorted = sort_pairs_by_length(pairs, min_length, max_length, [])
  let acc =
    BuildAcc(
      base: dict.new(),
      limit: dict.new(),
      symbols: dict.new(),
      symbol_index: 0,
      code: 0,
      prev_length: 0,
    )
  let acc = canonical_loop(sorted, acc)
  let final_limit = case acc.prev_length {
    0 -> acc.limit
    _ -> dict.insert(acc.limit, acc.prev_length, acc.code - 1)
  }
  Ok(HuffmanTable(
    min_length: min_length,
    max_length: max_length,
    base: acc.base,
    limit: final_limit,
    symbols: acc.symbols,
  ))
}

type BuildAcc {
  BuildAcc(
    base: dict.Dict(Int, Int),
    limit: dict.Dict(Int, Int),
    symbols: dict.Dict(Int, Int),
    symbol_index: Int,
    code: Int,
    prev_length: Int,
  )
}

fn canonical_loop(sorted: List(#(Int, Int)), acc: BuildAcc) -> BuildAcc {
  case sorted {
    [] -> acc
    [#(sym, length), ..rest] -> {
      let #(code, base, limit) = case length == acc.prev_length {
        True -> #(acc.code, acc.base, acc.limit)
        False ->
          case acc.prev_length {
            0 -> #(
              0,
              dict.insert(acc.base, length, acc.symbol_index),
              acc.limit,
            )
            _ -> {
              let shift = length - acc.prev_length
              let prev_limit =
                dict.insert(acc.limit, acc.prev_length, acc.code - 1)
              let new_code = int.bitwise_shift_left(acc.code, shift)
              #(
                new_code,
                dict.insert(acc.base, length, acc.symbol_index - new_code),
                prev_limit,
              )
            }
          }
      }
      let symbols = dict.insert(acc.symbols, acc.symbol_index, sym)
      canonical_loop(
        rest,
        BuildAcc(
          base: base,
          limit: limit,
          symbols: symbols,
          symbol_index: acc.symbol_index + 1,
          code: code + 1,
          prev_length: length,
        ),
      )
    }
  }
}

fn enumerate_lengths(
  lengths: List(Int),
  index: Int,
  acc: List(#(Int, Int)),
) -> List(#(Int, Int)) {
  case lengths {
    [] -> list.reverse(acc)
    [head, ..rest] ->
      enumerate_lengths(rest, index + 1, [#(index, head), ..acc])
  }
}

fn find_min_length(lengths: List(Int), best: Int) -> Int {
  case lengths {
    [] ->
      case best {
        21 -> 1
        _ -> best
      }
    [head, ..rest] -> {
      let best = case head < best {
        True -> head
        False -> best
      }
      find_min_length(rest, best)
    }
  }
}

fn find_max_length(lengths: List(Int), best: Int) -> Int {
  case lengths {
    [] -> best
    [head, ..rest] -> {
      let best = case head > best {
        True -> head
        False -> best
      }
      find_max_length(rest, best)
    }
  }
}

fn sort_pairs_by_length(
  pairs: List(#(Int, Int)),
  length: Int,
  max_length: Int,
  acc: List(#(Int, Int)),
) -> List(#(Int, Int)) {
  case length > max_length {
    True -> list.reverse(acc)
    False -> {
      let bucket = list.filter(pairs, fn(pair) { pair.1 == length })
      sort_pairs_by_length(
        pairs,
        length + 1,
        max_length,
        prepend_reversed(bucket, acc),
      )
    }
  }
}

fn prepend_reversed(
  values: List(#(Int, Int)),
  acc: List(#(Int, Int)),
) -> List(#(Int, Int)) {
  case values {
    [] -> acc
    [head, ..rest] -> prepend_reversed(rest, [head, ..acc])
  }
}

// -- huffman decode + MTF inverse + RLE2 (RUNA/RUNB) --------------------

fn list_to_dict(
  values: List(a),
  index: Int,
  acc: dict.Dict(Int, a),
) -> dict.Dict(Int, a) {
  case values {
    [] -> acc
    [head, ..rest] ->
      list_to_dict(rest, index + 1, dict.insert(acc, index, head))
  }
}

// Trampolined symbol-decode loop.  See `inflate_huffman_block` in
// packkit/deflate for the rationale — the recursive self-call has to
// sit at the function's outer-`case` tail position (not buried inside
// `use ... <- result.try(...)` closures) for Gleam's JS backend to
// rewrite it to a `while`.  Splitting the body into `decode_huffman_step`
// (returns Done/Continue) and a thin `case` outer keeps the JS stack
// at a small constant regardless of how many symbols a bzip2 block
// emits.
fn decode_huffman_stream(
  reader: Reader,
  tables: dict.Dict(Int, HuffmanTable),
  selectors: dict.Dict(Int, Int),
  eob: Int,
  mtf: List(Int),
  num_syms: Int,
  symbol_count: Int,
  pending_run: Int,
  run_weight: Int,
  out_rev: List(Int),
  out_len: Int,
  limits: limit.Limits,
) -> Result(#(dict.Dict(Int, Int), Int, Reader), error.CodecError) {
  case
    decode_huffman_step(
      reader,
      tables,
      selectors,
      eob,
      mtf,
      symbol_count,
      pending_run,
      run_weight,
      out_rev,
      out_len,
      limits,
    )
  {
    Error(err) -> Error(err)
    Ok(HuffmanStreamDone(final_out_rev, final_out_len, final_reader)) -> {
      let _ = num_syms
      let l_string =
        list_to_indexed_dict(list.reverse(final_out_rev), 0, dict.new())
      Ok(#(l_string, final_out_len, final_reader))
    }
    Ok(HuffmanStreamContinue(
      next_reader,
      next_mtf,
      next_symbol_count,
      next_pending_run,
      next_run_weight,
      next_out_rev,
      next_out_len,
    )) ->
      decode_huffman_stream(
        next_reader,
        tables,
        selectors,
        eob,
        next_mtf,
        num_syms,
        next_symbol_count,
        next_pending_run,
        next_run_weight,
        next_out_rev,
        next_out_len,
        limits,
      )
  }
}

type HuffmanStreamStep {
  HuffmanStreamDone(out_rev: List(Int), out_len: Int, reader: Reader)
  HuffmanStreamContinue(
    reader: Reader,
    mtf: List(Int),
    symbol_count: Int,
    pending_run: Int,
    run_weight: Int,
    out_rev: List(Int),
    out_len: Int,
  )
}

fn decode_huffman_step(
  reader: Reader,
  tables: dict.Dict(Int, HuffmanTable),
  selectors: dict.Dict(Int, Int),
  eob: Int,
  mtf: List(Int),
  symbol_count: Int,
  pending_run: Int,
  run_weight: Int,
  out_rev: List(Int),
  out_len: Int,
  limits: limit.Limits,
) -> Result(HuffmanStreamStep, error.CodecError) {
  let group_index = symbol_count / group_size
  let selector = case dict.get(selectors, group_index) {
    Ok(v) -> v
    Error(_) -> 0
  }
  let table = case dict.get(tables, selector) {
    Ok(v) -> v
    Error(_) ->
      HuffmanTable(
        min_length: 1,
        max_length: 1,
        base: dict.new(),
        limit: dict.new(),
        symbols: dict.new(),
      )
  }
  use #(symbol, reader) <- result.try(decode_one_symbol(reader, table))
  case symbol {
    s if s == eob -> {
      use #(out_rev, out_len) <- result.try(flush_run(
        out_rev,
        out_len,
        mtf,
        pending_run,
        limits,
      ))
      Ok(HuffmanStreamDone(out_rev, out_len, reader))
    }
    0 ->
      Ok(HuffmanStreamContinue(
        reader,
        mtf,
        symbol_count + 1,
        pending_run + run_weight,
        run_weight * 2,
        out_rev,
        out_len,
      ))
    1 ->
      Ok(HuffmanStreamContinue(
        reader,
        mtf,
        symbol_count + 1,
        pending_run + 2 * run_weight,
        run_weight * 2,
        out_rev,
        out_len,
      ))
    other -> {
      use #(out_rev, out_len) <- result.try(flush_run(
        out_rev,
        out_len,
        mtf,
        pending_run,
        limits,
      ))
      let mtf_index = other - 1
      use #(byte, new_mtf) <- result.try(mtf_pick_byte(mtf, mtf_index))
      use #(out_rev, out_len) <- result.try(emit_byte(
        out_rev,
        out_len,
        byte,
        limits,
      ))
      Ok(HuffmanStreamContinue(
        reader,
        new_mtf,
        symbol_count + 1,
        0,
        1,
        out_rev,
        out_len,
      ))
    }
  }
}

fn flush_run(
  out_rev: List(Int),
  out_len: Int,
  mtf: List(Int),
  pending: Int,
  limits: limit.Limits,
) -> Result(#(List(Int), Int), error.CodecError) {
  case pending {
    0 -> Ok(#(out_rev, out_len))
    _ -> {
      let front = case mtf {
        [head, ..] -> head
        [] -> 0
      }
      use <- bool.guard(
        when: out_len + pending > limit.max_output_bytes(limits),
        return: Error(error.CodecLimitExceeded(
          limit: "max_output_bytes",
          actual: out_len + pending,
        )),
      )
      let out_rev = repeat_prepend(front, pending, out_rev)
      Ok(#(out_rev, out_len + pending))
    }
  }
}

fn emit_byte(
  out_rev: List(Int),
  out_len: Int,
  byte: Int,
  limits: limit.Limits,
) -> Result(#(List(Int), Int), error.CodecError) {
  use <- bool.guard(
    when: out_len + 1 > limit.max_output_bytes(limits),
    return: Error(error.CodecLimitExceeded(
      limit: "max_output_bytes",
      actual: out_len + 1,
    )),
  )
  Ok(#([byte, ..out_rev], out_len + 1))
}

fn repeat_prepend(value: Int, count: Int, acc: List(Int)) -> List(Int) {
  case count {
    0 -> acc
    _ -> repeat_prepend(value, count - 1, [value, ..acc])
  }
}

fn mtf_pick_byte(
  mtf: List(Int),
  index: Int,
) -> Result(#(Int, List(Int)), error.CodecError) {
  case mtf_pick_loop(mtf, index, []) {
    Ok(#(byte, prefix, rest)) ->
      Ok(#(byte, [byte, ..list.append(list.reverse(prefix), rest)]))
    Error(_) ->
      Error(error.CodecInvalidData(message: "bzip2 MTF index out of range"))
  }
}

fn mtf_pick_loop(
  mtf: List(Int),
  index: Int,
  prefix: List(Int),
) -> Result(#(Int, List(Int), List(Int)), Nil) {
  case mtf, index {
    [head, ..rest], 0 -> Ok(#(head, prefix, rest))
    [head, ..rest], _ -> mtf_pick_loop(rest, index - 1, [head, ..prefix])
    [], _ -> Error(Nil)
  }
}

fn list_to_indexed_dict(
  values: List(Int),
  index: Int,
  acc: dict.Dict(Int, Int),
) -> dict.Dict(Int, Int) {
  case values {
    [] -> acc
    [head, ..rest] ->
      list_to_indexed_dict(rest, index + 1, dict.insert(acc, index, head))
  }
}

fn decode_one_symbol(
  reader: Reader,
  table: HuffmanTable,
) -> Result(#(Int, Reader), error.CodecError) {
  use #(code, reader) <- result.try(read_bits(reader, table.min_length))
  walk_huffman(reader, table, table.min_length, code)
}

fn walk_huffman(
  reader: Reader,
  table: HuffmanTable,
  length: Int,
  code: Int,
) -> Result(#(Int, Reader), error.CodecError) {
  case length > table.max_length {
    True ->
      Error(error.CodecInvalidData(message: "bzip2 huffman code overflow"))
    False -> {
      let limit_value = case dict.get(table.limit, length) {
        Ok(v) -> v
        Error(_) -> -1
      }
      case code <= limit_value {
        True -> {
          let base_value = case dict.get(table.base, length) {
            Ok(v) -> v
            Error(_) -> 0
          }
          let index = base_value + code
          let symbol = case dict.get(table.symbols, index) {
            Ok(v) -> v
            Error(_) -> -1
          }
          case symbol < 0 {
            True ->
              Error(error.CodecInvalidData(
                message: "bzip2 huffman symbol lookup failed",
              ))
            False -> Ok(#(symbol, reader))
          }
        }
        False -> {
          use #(bit, reader) <- result.try(read_bits(reader, 1))
          walk_huffman(
            reader,
            table,
            length + 1,
            int.bitwise_or(int.bitwise_shift_left(code, 1), bit),
          )
        }
      }
    }
  }
}

// -- inverse BWT and RLE1 ------------------------------------------------

fn inverse_bwt(
  l_string: dict.Dict(Int, Int),
  length: Int,
  orig_ptr: Int,
) -> dict.Dict(Int, Int) {
  let counts = count_bytes(l_string, 0, length, dict.new())
  let cumulative = build_cumulative(counts, 0, 0, dict.new())
  let t = build_t(l_string, 0, length, cumulative, dict.new())
  walk_bwt(l_string, t, orig_ptr, 0, length, dict.new())
}

fn count_bytes(
  l_string: dict.Dict(Int, Int),
  index: Int,
  length: Int,
  acc: dict.Dict(Int, Int),
) -> dict.Dict(Int, Int) {
  case index >= length {
    True -> acc
    False -> {
      let byte = case dict.get(l_string, index) {
        Ok(v) -> v
        Error(_) -> 0
      }
      let current = case dict.get(acc, byte) {
        Ok(v) -> v
        Error(_) -> 0
      }
      count_bytes(
        l_string,
        index + 1,
        length,
        dict.insert(acc, byte, current + 1),
      )
    }
  }
}

fn build_cumulative(
  counts: dict.Dict(Int, Int),
  symbol: Int,
  acc: Int,
  out: dict.Dict(Int, Int),
) -> dict.Dict(Int, Int) {
  case symbol >= 256 {
    True -> out
    False -> {
      let out = dict.insert(out, symbol, acc)
      let n = case dict.get(counts, symbol) {
        Ok(v) -> v
        Error(_) -> 0
      }
      build_cumulative(counts, symbol + 1, acc + n, out)
    }
  }
}

fn build_t(
  l_string: dict.Dict(Int, Int),
  index: Int,
  length: Int,
  cumulative: dict.Dict(Int, Int),
  t: dict.Dict(Int, Int),
) -> dict.Dict(Int, Int) {
  case index >= length {
    True -> t
    False -> {
      let byte = case dict.get(l_string, index) {
        Ok(v) -> v
        Error(_) -> 0
      }
      let slot = case dict.get(cumulative, byte) {
        Ok(v) -> v
        Error(_) -> 0
      }
      let cumulative = dict.insert(cumulative, byte, slot + 1)
      build_t(
        l_string,
        index + 1,
        length,
        cumulative,
        dict.insert(t, slot, index),
      )
    }
  }
}

fn walk_bwt(
  l_string: dict.Dict(Int, Int),
  t: dict.Dict(Int, Int),
  pos: Int,
  index: Int,
  length: Int,
  out: dict.Dict(Int, Int),
) -> dict.Dict(Int, Int) {
  case index >= length {
    True -> out
    False -> {
      let next = case dict.get(t, pos) {
        Ok(v) -> v
        Error(_) -> 0
      }
      let byte = case dict.get(l_string, next) {
        Ok(v) -> v
        Error(_) -> 0
      }
      walk_bwt(
        l_string,
        t,
        next,
        index + 1,
        length,
        dict.insert(out, index, byte),
      )
    }
  }
}

// -- RLE1 inverse --------------------------------------------------------

fn rle1_decode(input: dict.Dict(Int, Int), length: Int) -> BitArray {
  rle1_decode_loop(input, 0, length, -1, 0, [])
  |> list.reverse
  |> bytes_list_to_bit_array(<<>>)
}

fn rle1_decode_loop(
  input: dict.Dict(Int, Int),
  index: Int,
  length: Int,
  last_byte: Int,
  run: Int,
  acc: List(Int),
) -> List(Int) {
  case index >= length {
    True -> acc
    False -> {
      let byte = case dict.get(input, index) {
        Ok(v) -> v
        Error(_) -> 0
      }
      case run == 4 {
        True -> {
          let acc = repeat_prepend(last_byte, byte, acc)
          rle1_decode_loop(input, index + 1, length, -1, 0, acc)
        }
        False -> {
          case byte == last_byte {
            True ->
              rle1_decode_loop(input, index + 1, length, byte, run + 1, [
                byte,
                ..acc
              ])
            False ->
              rle1_decode_loop(input, index + 1, length, byte, 1, [byte, ..acc])
          }
        }
      }
    }
  }
}

fn bytes_list_to_bit_array(bytes: List(Int), acc: BitArray) -> BitArray {
  case bytes {
    [] -> acc
    [head, ..rest] -> bytes_list_to_bit_array(rest, <<acc:bits, head>>)
  }
}

// -- bit reader (MSB-first) ---------------------------------------------

type Reader {
  Reader(bits: Int, buffer: Int, source: BitArray, overflow: Bool)
}

fn new_reader(source: BitArray) -> Reader {
  Reader(bits: 0, buffer: 0, source: source, overflow: False)
}

fn refill(reader: Reader, needed: Int) -> Reader {
  case reader.bits >= needed || reader.overflow {
    True -> reader
    False ->
      case reader.source {
        <<b, rest:bytes>> ->
          refill(
            Reader(
              bits: reader.bits + 8,
              buffer: int.bitwise_or(
                int.bitwise_shift_left(reader.buffer, 8),
                b,
              ),
              source: rest,
              overflow: False,
            ),
            needed,
          )
        _ ->
          Reader(
            bits: reader.bits,
            buffer: reader.buffer,
            source: <<>>,
            overflow: True,
          )
      }
  }
}

fn read_bits(
  reader: Reader,
  count: Int,
) -> Result(#(Int, Reader), error.CodecError) {
  let reader = refill(reader, count)
  case reader.bits < count {
    True -> Error(error.CodecInvalidData(message: "truncated bzip2 stream"))
    False -> {
      let new_bits = reader.bits - count
      let mask = int.bitwise_shift_left(1, count) - 1
      let value =
        int.bitwise_and(int.bitwise_shift_right(reader.buffer, new_bits), mask)
      let buffer_mask = int.bitwise_shift_left(1, new_bits) - 1
      let new_buffer = int.bitwise_and(reader.buffer, buffer_mask)
      Ok(#(
        value,
        Reader(
          bits: new_bits,
          buffer: new_buffer,
          source: reader.source,
          overflow: reader.overflow,
        ),
      ))
    }
  }
}

// -- encoder pipeline --------------------------------------------------

fn encode_block(writer: Writer, bytes: BitArray) -> Writer {
  let block_crc = checksum.bzip2_crc32(bytes)
  let rle1 = rle1_encode(bytes)
  let n = list.length(rle1)
  let #(l_string, orig_ptr) = bwt_forward(rle1, n)
  let unique = sorted_unique_bytes(l_string)
  let mtf_indices = mtf_forward(l_string, unique)
  let symbols = rle2_encode(mtf_indices, list.length(unique) + 1)
  let alphabet_size = list.length(unique) + 2
  let lengths = build_huffman_lengths(symbols, alphabet_size)
  let codes = canonical_codes(lengths)
  let num_groups = case list.length(symbols) {
    0 -> 1
    sn -> { sn + group_size - 1 } / group_size
  }
  let writer =
    writer
    |> write_bits_msb(block_magic_high, 24)
    |> write_bits_msb(block_magic_low, 24)
    |> write_bits_msb(block_crc, 32)
    |> write_bits_msb(0, 1)
    |> write_bits_msb(orig_ptr, 24)
  let writer = emit_symbol_map(writer, unique)
  let writer = write_bits_msb(writer, 2, 3)
  let writer = write_bits_msb(writer, num_groups, 15)
  let writer = emit_selectors(writer, num_groups)
  let writer = emit_two_tables(writer, lengths, alphabet_size)
  emit_huffman_data(writer, symbols, lengths, codes)
}

// -- RLE1 forward ------------------------------------------------------

fn rle1_encode(bytes: BitArray) -> List(Int) {
  rle1_loop(bytes, -1, 0, [])
}

fn rle1_loop(bytes: BitArray, last: Int, run: Int, acc: List(Int)) -> List(Int) {
  case bytes {
    <<b, rest:bytes>> ->
      case b == last {
        True ->
          case run {
            r if r < 4 -> rle1_loop(rest, last, run + 1, [b, ..acc])
            r if r < 259 -> {
              // run is currently 4..258, but bzip2 caps at 259 (extra
              // byte stores 0..255).  When we hit r==258 we're about to
              // consume the 259th byte of the run — emit the count byte
              // 255 (= 4 + 255 = 259 total) and reset, but do NOT emit
              // `b` as raw: it is already counted by the closing 255.
              case r >= 4 + 254 {
                True -> rle1_loop(rest, -1, 0, [255, ..acc])
                False -> rle1_loop(rest, last, run + 1, acc)
              }
            }
            _ -> rle1_loop(rest, last, run + 1, acc)
          }
        False ->
          case run >= 4 {
            True -> {
              let extra = run - 4
              rle1_loop(rest, b, 1, [b, extra, ..acc])
            }
            False -> rle1_loop(rest, b, 1, [b, ..acc])
          }
      }
    _ ->
      case run >= 4 {
        True -> {
          let extra = run - 4
          list.reverse([extra, ..acc])
        }
        False -> list.reverse(acc)
      }
  }
}

// -- BWT forward (naive sort of rotations) ---------------------------

fn bwt_forward(input: List(Int), n: Int) -> #(dict.Dict(Int, Int), Int) {
  let table = list_to_dict(input, 0, dict.new())
  let indices = list_range(0, n - 1, [])
  let sorted =
    list.sort(indices, fn(a, b) { compare_rotations(table, n, a, b) })
  let l_dict = build_l_dict(sorted, table, n, 0, dict.new())
  let orig_ptr = find_index(sorted, 0, 0)
  #(l_dict, orig_ptr)
}

fn list_range(low: Int, high: Int, acc: List(Int)) -> List(Int) {
  case low > high {
    True -> list.reverse(acc)
    False -> list_range(low + 1, high, [low, ..acc])
  }
}

fn compare_rotations(
  table: dict.Dict(Int, Int),
  n: Int,
  a: Int,
  b: Int,
) -> order.Order {
  compare_loop(table, n, a, b, 0)
}

fn compare_loop(
  table: dict.Dict(Int, Int),
  n: Int,
  a: Int,
  b: Int,
  offset: Int,
) -> order.Order {
  case offset >= n {
    True -> order.Eq
    False -> {
      let ba = byte_at_index(table, mod_index(a + offset, n))
      let bb = byte_at_index(table, mod_index(b + offset, n))
      case ba == bb {
        True -> compare_loop(table, n, a, b, offset + 1)
        False -> int.compare(ba, bb)
      }
    }
  }
}

fn byte_at_index(table: dict.Dict(Int, Int), index: Int) -> Int {
  case dict.get(table, index) {
    Ok(v) -> v
    Error(_) -> 0
  }
}

fn mod_index(value: Int, n: Int) -> Int {
  case n {
    0 -> 0
    _ -> {
      let r = value - { value / n } * n
      case r < 0 {
        True -> r + n
        False -> r
      }
    }
  }
}

fn build_l_dict(
  sorted: List(Int),
  table: dict.Dict(Int, Int),
  n: Int,
  index: Int,
  acc: dict.Dict(Int, Int),
) -> dict.Dict(Int, Int) {
  case sorted {
    [] -> acc
    [head, ..rest] -> {
      let byte = byte_at_index(table, mod_index(head + n - 1, n))
      build_l_dict(rest, table, n, index + 1, dict.insert(acc, index, byte))
    }
  }
}

fn find_index(values: List(Int), target: Int, index: Int) -> Int {
  case values {
    [head, ..] if head == target -> index
    [_, ..rest] -> find_index(rest, target, index + 1)
    [] -> 0
  }
}

// -- MTF forward + RLE2 ------------------------------------------------

fn sorted_unique_bytes(l_string: dict.Dict(Int, Int)) -> List(Int) {
  let unique_dict =
    dict.fold(l_string, dict.new(), fn(acc, _key, value) {
      dict.insert(acc, value, True)
    })
  let bytes = dict.keys(unique_dict)
  list.sort(bytes, int.compare)
}

fn mtf_forward(l_string: dict.Dict(Int, Int), unique: List(Int)) -> List(Int) {
  mtf_forward_loop(l_string, 0, dict.size(l_string), unique, [])
}

fn mtf_forward_loop(
  l_string: dict.Dict(Int, Int),
  index: Int,
  length: Int,
  stack: List(Int),
  acc: List(Int),
) -> List(Int) {
  case index >= length {
    True -> list.reverse(acc)
    False -> {
      let byte = byte_at_index(l_string, index)
      let #(pos, new_stack) = find_and_pop(stack, byte, 0, [])
      mtf_forward_loop(l_string, index + 1, length, [byte, ..new_stack], [
        pos,
        ..acc
      ])
    }
  }
}

fn find_and_pop(
  stack: List(Int),
  target: Int,
  pos: Int,
  prefix: List(Int),
) -> #(Int, List(Int)) {
  case stack {
    [head, ..rest] if head == target -> #(
      pos,
      list.append(list.reverse(prefix), rest),
    )
    [head, ..rest] -> find_and_pop(rest, target, pos + 1, [head, ..prefix])
    [] -> #(pos, list.reverse(prefix))
  }
}

fn rle2_encode(mtf: List(Int), eob: Int) -> List(Int) {
  rle2_loop(mtf, 0, eob, [])
}

fn rle2_loop(
  mtf: List(Int),
  zero_run: Int,
  eob: Int,
  acc: List(Int),
) -> List(Int) {
  case mtf {
    [0, ..rest] -> rle2_loop(rest, zero_run + 1, eob, acc)
    [n, ..rest] -> {
      let acc = flush_zero_run(zero_run, acc)
      rle2_loop(rest, 0, eob, [n + 1, ..acc])
    }
    [] -> {
      let acc = flush_zero_run(zero_run, acc)
      list.reverse([eob, ..acc])
    }
  }
}

fn flush_zero_run(count: Int, acc: List(Int)) -> List(Int) {
  case count {
    0 -> acc
    _ -> emit_runa_runb(count + 1, acc)
  }
}

fn emit_runa_runb(value: Int, acc: List(Int)) -> List(Int) {
  // value = (run_length + 1).  Drop the most-significant bit and
  // emit the remaining bits LSB-first as RUNA (bit 0) or RUNB (bit 1).
  case value {
    1 -> acc
    _ -> {
      let bit = int.bitwise_and(value, 1)
      let next = int.bitwise_shift_right(value, 1)
      emit_runa_runb(next, [bit, ..acc])
    }
  }
}

// -- Huffman tree (length-limited) ------------------------------------

fn build_huffman_lengths(
  symbols: List(Int),
  alphabet_size: Int,
) -> dict.Dict(Int, Int) {
  let freq = count_frequencies(symbols, dict.new())
  let freq = pad_min_frequencies(freq, 0, alphabet_size)
  package_merge_lengths(freq, alphabet_size, 17)
}

fn count_frequencies(
  symbols: List(Int),
  acc: dict.Dict(Int, Int),
) -> dict.Dict(Int, Int) {
  case symbols {
    [] -> acc
    [head, ..rest] -> {
      let current = case dict.get(acc, head) {
        Ok(v) -> v
        Error(_) -> 0
      }
      count_frequencies(rest, dict.insert(acc, head, current + 1))
    }
  }
}

fn pad_min_frequencies(
  freq: dict.Dict(Int, Int),
  symbol: Int,
  alphabet_size: Int,
) -> dict.Dict(Int, Int) {
  case symbol >= alphabet_size {
    True -> freq
    False -> {
      let freq = case dict.get(freq, symbol) {
        Ok(_) -> freq
        Error(_) -> dict.insert(freq, symbol, 1)
      }
      pad_min_frequencies(freq, symbol + 1, alphabet_size)
    }
  }
}

// Simple length-limited Huffman via repeated rebalancing.  For small
// alphabets (≤ 258) this terminates quickly and produces a valid
// canonical code that respects the bzip2 length cap of 17.
fn package_merge_lengths(
  freq: dict.Dict(Int, Int),
  alphabet_size: Int,
  max_length: Int,
) -> dict.Dict(Int, Int) {
  let lengths = compute_huffman_lengths(freq, alphabet_size)
  case max_length_in_dict(lengths, 0, alphabet_size, 0) > max_length {
    False -> lengths
    True ->
      package_merge_lengths(
        flatten_frequencies(freq),
        alphabet_size,
        max_length,
      )
  }
}

fn flatten_frequencies(freq: dict.Dict(Int, Int)) -> dict.Dict(Int, Int) {
  // Halve every frequency and round up, then add the minimum so all
  // frequencies stay ≥ 1.  This compresses the dynamic range and
  // shortens the longest codes.
  dict.fold(freq, dict.new(), fn(acc, sym, count) {
    let new_count = case count {
      n if n <= 1 -> 1
      n -> { n + 1 } / 2 + 1
    }
    dict.insert(acc, sym, new_count)
  })
}

fn max_length_in_dict(
  lengths: dict.Dict(Int, Int),
  symbol: Int,
  alphabet_size: Int,
  best: Int,
) -> Int {
  case symbol >= alphabet_size {
    True -> best
    False -> {
      let len = case dict.get(lengths, symbol) {
        Ok(v) -> v
        Error(_) -> 0
      }
      let best = case len > best {
        True -> len
        False -> best
      }
      max_length_in_dict(lengths, symbol + 1, alphabet_size, best)
    }
  }
}

// Standard Huffman tree builder using node merging.
fn compute_huffman_lengths(
  freq: dict.Dict(Int, Int),
  alphabet_size: Int,
) -> dict.Dict(Int, Int) {
  let nodes = build_leaves(freq, 0, alphabet_size, [])
  let merged_root = merge_nodes(nodes)
  collect_lengths(merged_root, 0, dict.new())
}

type HuffNode {
  HuffLeaf(symbol: Int, weight: Int)
  HuffInternal(weight: Int, left: HuffNode, right: HuffNode)
}

fn build_leaves(
  freq: dict.Dict(Int, Int),
  symbol: Int,
  alphabet_size: Int,
  acc: List(HuffNode),
) -> List(HuffNode) {
  case symbol >= alphabet_size {
    True -> acc
    False -> {
      let weight = case dict.get(freq, symbol) {
        Ok(v) -> v
        Error(_) -> 0
      }
      build_leaves(freq, symbol + 1, alphabet_size, [
        HuffLeaf(symbol: symbol, weight: weight),
        ..acc
      ])
    }
  }
}

fn merge_nodes(nodes: List(HuffNode)) -> HuffNode {
  case nodes {
    [single] -> single
    _ -> {
      let sorted =
        list.sort(nodes, fn(a, b) {
          int.compare(node_weight(a), node_weight(b))
        })
      case sorted {
        [a, b, ..rest] ->
          merge_nodes([
            HuffInternal(
              weight: node_weight(a) + node_weight(b),
              left: a,
              right: b,
            ),
            ..rest
          ])
        _ -> HuffLeaf(symbol: 0, weight: 0)
      }
    }
  }
}

fn node_weight(node: HuffNode) -> Int {
  case node {
    HuffLeaf(_, w) -> w
    HuffInternal(w, _, _) -> w
  }
}

fn collect_lengths(
  node: HuffNode,
  depth: Int,
  acc: dict.Dict(Int, Int),
) -> dict.Dict(Int, Int) {
  case node {
    HuffLeaf(symbol, _) -> {
      let depth = case depth {
        0 -> 1
        _ -> depth
      }
      dict.insert(acc, symbol, depth)
    }
    HuffInternal(_, left, right) -> {
      let acc = collect_lengths(left, depth + 1, acc)
      collect_lengths(right, depth + 1, acc)
    }
  }
}

// -- canonical Huffman codes ------------------------------------------

fn canonical_codes(lengths: dict.Dict(Int, Int)) -> dict.Dict(Int, Int) {
  let pairs = dict.to_list(lengths)
  let sorted =
    list.sort(pairs, fn(a, b) {
      case int.compare(a.1, b.1) {
        order.Eq -> int.compare(a.0, b.0)
        other -> other
      }
    })
  assign_codes(sorted, 0, 0, dict.new())
}

fn assign_codes(
  pairs: List(#(Int, Int)),
  code: Int,
  prev_length: Int,
  acc: dict.Dict(Int, Int),
) -> dict.Dict(Int, Int) {
  case pairs {
    [] -> acc
    [#(sym, length), ..rest] -> {
      let code = case prev_length {
        0 -> 0
        _ -> int.bitwise_shift_left(code, length - prev_length)
      }
      assign_codes(rest, code + 1, length, dict.insert(acc, sym, code))
    }
  }
}

// -- block emission -----------------------------------------------------

fn emit_symbol_map(writer: Writer, unique: List(Int)) -> Writer {
  let group_dict = bytes_to_group_dict(unique, dict.new())
  let group_used = compute_group_used(group_dict, 0, dict.new())
  let writer = emit_group_high(writer, group_used, 0)
  emit_group_bitmaps(writer, group_used, group_dict, 0)
}

fn bytes_to_group_dict(
  bytes: List(Int),
  acc: dict.Dict(Int, List(Int)),
) -> dict.Dict(Int, List(Int)) {
  case bytes {
    [] -> acc
    [b, ..rest] -> {
      let group = b / 16
      let existing = case dict.get(acc, group) {
        Ok(v) -> v
        Error(_) -> []
      }
      bytes_to_group_dict(rest, dict.insert(acc, group, [b, ..existing]))
    }
  }
}

fn compute_group_used(
  group_dict: dict.Dict(Int, List(Int)),
  group: Int,
  acc: dict.Dict(Int, Bool),
) -> dict.Dict(Int, Bool) {
  case group >= 16 {
    True -> acc
    False -> {
      let used = case dict.get(group_dict, group) {
        Ok(_) -> True
        Error(_) -> False
      }
      compute_group_used(group_dict, group + 1, dict.insert(acc, group, used))
    }
  }
}

fn emit_group_high(
  writer: Writer,
  group_used: dict.Dict(Int, Bool),
  group: Int,
) -> Writer {
  case group >= 16 {
    True -> writer
    False -> {
      let bit = case dict.get(group_used, group) {
        Ok(True) -> 1
        _ -> 0
      }
      emit_group_high(write_bits_msb(writer, bit, 1), group_used, group + 1)
    }
  }
}

fn emit_group_bitmaps(
  writer: Writer,
  group_used: dict.Dict(Int, Bool),
  group_dict: dict.Dict(Int, List(Int)),
  group: Int,
) -> Writer {
  case group >= 16 {
    True -> writer
    False ->
      case dict.get(group_used, group) {
        Ok(True) -> {
          let bytes = case dict.get(group_dict, group) {
            Ok(v) -> v
            Error(_) -> []
          }
          let writer = emit_bitmap_for_group(writer, bytes, group, 0)
          emit_group_bitmaps(writer, group_used, group_dict, group + 1)
        }
        _ -> emit_group_bitmaps(writer, group_used, group_dict, group + 1)
      }
  }
}

fn emit_bitmap_for_group(
  writer: Writer,
  bytes: List(Int),
  group: Int,
  offset: Int,
) -> Writer {
  case offset >= 16 {
    True -> writer
    False -> {
      let target = group * 16 + offset
      let bit = case list.contains(bytes, target) {
        True -> 1
        False -> 0
      }
      emit_bitmap_for_group(
        write_bits_msb(writer, bit, 1),
        bytes,
        group,
        offset + 1,
      )
    }
  }
}

fn emit_selectors(writer: Writer, num_groups: Int) -> Writer {
  // All-zero selector list: every group picks table 0, encoded as a
  // single 0 bit (unary 0).
  emit_selectors_loop(writer, num_groups)
}

fn emit_selectors_loop(writer: Writer, remaining: Int) -> Writer {
  case remaining {
    0 -> writer
    _ -> emit_selectors_loop(write_bits_msb(writer, 0, 1), remaining - 1)
  }
}

fn emit_two_tables(
  writer: Writer,
  lengths: dict.Dict(Int, Int),
  alphabet_size: Int,
) -> Writer {
  let writer = emit_table_lengths(writer, lengths, alphabet_size)
  emit_table_lengths(writer, lengths, alphabet_size)
}

fn emit_table_lengths(
  writer: Writer,
  lengths: dict.Dict(Int, Int),
  alphabet_size: Int,
) -> Writer {
  // The 5-bit prefix is the running length BEFORE the first symbol's
  // adjustment.  Choosing the length of symbol 0 lets that adjustment
  // collapse to a single "0" bit.
  let first = case dict.get(lengths, 0) {
    Ok(v) -> v
    Error(_) -> 1
  }
  let writer = write_bits_msb(writer, first, 5)
  emit_lengths_diff(writer, lengths, 0, alphabet_size, first)
}

fn emit_lengths_diff(
  writer: Writer,
  lengths: dict.Dict(Int, Int),
  symbol: Int,
  alphabet_size: Int,
  previous: Int,
) -> Writer {
  case symbol >= alphabet_size {
    True -> writer
    False -> {
      let target = case dict.get(lengths, symbol) {
        Ok(v) -> v
        Error(_) -> previous
      }
      let writer = emit_length_diff(writer, previous, target)
      emit_lengths_diff(writer, lengths, symbol + 1, alphabet_size, target)
    }
  }
}

fn emit_length_diff(writer: Writer, previous: Int, target: Int) -> Writer {
  case target == previous {
    True -> write_bits_msb(writer, 0, 1)
    False ->
      case target > previous {
        True -> {
          let writer = write_bits_msb(writer, 1, 1)
          let writer = write_bits_msb(writer, 0, 1)
          emit_length_diff(writer, previous + 1, target)
        }
        False -> {
          let writer = write_bits_msb(writer, 1, 1)
          let writer = write_bits_msb(writer, 1, 1)
          emit_length_diff(writer, previous - 1, target)
        }
      }
  }
}

fn emit_huffman_data(
  writer: Writer,
  symbols: List(Int),
  lengths: dict.Dict(Int, Int),
  codes: dict.Dict(Int, Int),
) -> Writer {
  case symbols {
    [] -> writer
    [head, ..rest] -> {
      let code = case dict.get(codes, head) {
        Ok(v) -> v
        Error(_) -> 0
      }
      let length = case dict.get(lengths, head) {
        Ok(v) -> v
        Error(_) -> 1
      }
      emit_huffman_data(
        write_bits_msb(writer, code, length),
        rest,
        lengths,
        codes,
      )
    }
  }
}

// -- MSB-first bit writer ---------------------------------------------

type Writer {
  Writer(bytes_rev: List(Int), buffer: Int, bits: Int)
}

fn new_writer() -> Writer {
  Writer(bytes_rev: [], buffer: 0, bits: 0)
}

fn write_bits_msb(writer: Writer, value: Int, count: Int) -> Writer {
  case count {
    0 -> writer
    _ -> {
      let masked = int.bitwise_and(value, mask_for(count))
      let buffer =
        int.bitwise_or(int.bitwise_shift_left(writer.buffer, count), masked)
      flush_writer_full_bytes(Writer(
        bytes_rev: writer.bytes_rev,
        buffer: buffer,
        bits: writer.bits + count,
      ))
    }
  }
}

fn mask_for(count: Int) -> Int {
  int.bitwise_shift_left(1, count) - 1
}

fn flush_writer_full_bytes(writer: Writer) -> Writer {
  case writer.bits >= 8 {
    False -> writer
    True -> {
      let shift = writer.bits - 8
      let byte =
        int.bitwise_and(int.bitwise_shift_right(writer.buffer, shift), 0xFF)
      let new_buffer = int.bitwise_and(writer.buffer, mask_for(shift))
      flush_writer_full_bytes(Writer(
        bytes_rev: [byte, ..writer.bytes_rev],
        buffer: new_buffer,
        bits: shift,
      ))
    }
  }
}

fn flush_writer_msb(writer: Writer) -> BitArray {
  let writer = case writer.bits {
    0 -> writer
    _ -> {
      let pad = 8 - writer.bits
      let shifted = int.bitwise_shift_left(writer.buffer, pad)
      let byte = int.bitwise_and(shifted, 0xFF)
      Writer(bytes_rev: [byte, ..writer.bytes_rev], buffer: 0, bits: 0)
    }
  }
  list_to_bit_array(list.reverse(writer.bytes_rev), <<>>)
}

fn list_to_bit_array(values: List(Int), acc: BitArray) -> BitArray {
  case values {
    [] -> acc
    [head, ..rest] -> list_to_bit_array(rest, <<acc:bits, head>>)
  }
}
