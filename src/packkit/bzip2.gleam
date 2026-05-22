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

/// Encode `bytes` as a bzip2 stream.  Not yet implemented.
pub fn encode(bytes _bytes: BitArray) -> Result(BitArray, error.CodecError) {
  Error(error.CodecNotImplemented(feature: "bzip2.encode"))
}

/// Decode a bzip2 stream using the shared default `Limits`.
pub fn decode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  decode_with_limits(bytes: bytes, limits: limit.default())
}

/// Decode a bzip2 stream using explicit `Limits`.
pub fn decode_with_limits(
  bytes bytes: BitArray,
  limits limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  use <- bool.guard(
    when: bit_array.byte_size(bytes) > limit.max_input_bytes(limits),
    return: Error(error.CodecLimitExceeded(
      limit: "max_input_bytes",
      value: bit_array.byte_size(bytes),
    )),
  )

  use rest <- result.try(parse_stream_header(bytes))
  decode_blocks(new_reader(rest), <<>>, 0, limits)
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

fn decode_blocks(
  reader: Reader,
  output: BitArray,
  combined_crc: Int,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
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
      decode_blocks(reader, new_output, combined_crc, limits)
    }
    h, l if h == eos_magic_high && l == eos_magic_low -> {
      use #(stream_crc, _reader) <- result.try(read_bits(reader, 32))
      case stream_crc == combined_crc {
        True -> Ok(output)
        False ->
          Error(error.CodecInvalidData(message: "bzip2 stream CRC mismatch"))
      }
    }
    _, _ ->
      Error(error.CodecInvalidData(message: "unexpected bzip2 block marker"))
  }
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
        value: projected,
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
      let _ = num_syms
      let l_string = list_to_indexed_dict(list.reverse(out_rev), 0, dict.new())
      Ok(#(l_string, out_len, reader))
    }
    0 ->
      decode_huffman_stream(
        reader,
        tables,
        selectors,
        eob,
        mtf,
        num_syms,
        symbol_count + 1,
        pending_run + run_weight,
        run_weight * 2,
        out_rev,
        out_len,
        limits,
      )
    1 ->
      decode_huffman_stream(
        reader,
        tables,
        selectors,
        eob,
        mtf,
        num_syms,
        symbol_count + 1,
        pending_run + 2 * run_weight,
        run_weight * 2,
        out_rev,
        out_len,
        limits,
      )
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
      decode_huffman_stream(
        reader,
        tables,
        selectors,
        eob,
        new_mtf,
        num_syms,
        symbol_count + 1,
        0,
        1,
        out_rev,
        out_len,
        limits,
      )
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
          value: out_len + pending,
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
      value: out_len + 1,
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
