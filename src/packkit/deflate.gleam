//// Pure Gleam DEFLATE (RFC 1951) encoder and decoder.
////
//// The decoder handles all three RFC 1951 block types (stored, fixed
//// Huffman, dynamic Huffman) and enforces the `Limits` resource budget
//// while decoding.  The encoder currently emits a sequence of stored
//// blocks: the output is a valid DEFLATE stream but does not compress
//// the payload.  A Huffman-coded encoder is intentionally left as
//// future work.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/result
import packkit/codec as codecs
import packkit/error
import packkit/limit

const max_bits: Int = 15

const max_length_code: Int = 285

const max_distance_code: Int = 29

const stored_block_max: Int = 65_535

/// Raw deflate codec smart constructor.
pub fn codec() -> codecs.Codec {
  codecs.deflate()
}

/// Decode a raw DEFLATE byte stream using default limits.
pub fn decode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  decode_with_limits(bytes: bytes, limits: limit.default())
}

/// Decode a raw DEFLATE byte stream using explicit limits.
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

  let reader = Reader(buffer: 0, bits: 0, source: bytes, overflow: False)
  case inflate(reader, <<>>, limits) {
    Ok(#(output, _)) -> Ok(output)
    Error(err) -> Error(err)
  }
}

/// Encode a byte stream as a sequence of stored DEFLATE blocks.
///
/// The output is a valid DEFLATE stream that any conforming decoder
/// can decompress, but it does not actually compress the payload.
/// A Huffman-coded encoder is a follow-up work item.
pub fn encode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  Ok(encode_stored(bytes))
}

// -- bit reader ----------------------------------------------------------

type Reader {
  Reader(buffer: Int, bits: Int, source: BitArray, overflow: Bool)
}

fn refill(reader: Reader, needed: Int) -> Reader {
  case reader.bits >= needed || reader.overflow {
    True -> reader
    False ->
      case reader.source {
        <<b, rest:bytes>> ->
          refill(
            Reader(
              buffer: int.bitwise_or(
                reader.buffer,
                int.bitwise_shift_left(b, reader.bits),
              ),
              bits: reader.bits + 8,
              source: rest,
              overflow: False,
            ),
            needed,
          )
        _ ->
          Reader(
            buffer: reader.buffer,
            bits: reader.bits + 8,
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
  let r = refill(reader, count)
  case r.overflow && r.bits < count {
    True ->
      Error(error.CodecInvalidData(message: "truncated deflate bit stream"))
    False -> {
      let mask = int.bitwise_shift_left(1, count) - 1
      let value = int.bitwise_and(r.buffer, mask)
      let next =
        Reader(
          buffer: int.bitwise_shift_right(r.buffer, count),
          bits: r.bits - count,
          source: r.source,
          overflow: r.overflow,
        )
      Ok(#(value, next))
    }
  }
}

fn skip_to_byte_boundary(reader: Reader) -> Reader {
  Reader(buffer: 0, bits: 0, source: reader.source, overflow: reader.overflow)
}

// -- huffman tree --------------------------------------------------------

type Tree {
  Tree(counts: List(Int), symbols: List(Int), max_sym: Int)
}

fn build_tree(lengths: List(Int)) -> Result(Tree, error.CodecError) {
  let max_sym = find_max_symbol(lengths, 0, -1, 0)
  let counts = count_lengths(lengths)
  use _ <- result.try(validate_counts(counts, 0, 1, 0))
  let symbols = sort_symbols_by_length(lengths, counts)
  let counts_normalized = case
    list.length(symbols) == 1,
    list_get(counts, 1, 0) == 1
  {
    True, True -> set_index(counts, 1, 2)
    _, _ -> counts
  }
  let symbols_normalized = case list.length(symbols) == 1 {
    True -> [single_symbol(symbols), max_sym + 1, ..[]]
    False -> symbols
  }
  Ok(Tree(
    counts: counts_normalized,
    symbols: symbols_normalized,
    max_sym: max_sym,
  ))
}

fn single_symbol(symbols: List(Int)) -> Int {
  case symbols {
    [head, ..] -> head
    [] -> 0
  }
}

fn find_max_symbol(
  lengths: List(Int),
  index: Int,
  best: Int,
  _unused: Int,
) -> Int {
  case lengths {
    [] -> best
    [0, ..rest] -> find_max_symbol(rest, index + 1, best, 0)
    [_, ..rest] -> find_max_symbol(rest, index + 1, index, 0)
  }
}

fn count_lengths(lengths: List(Int)) -> List(Int) {
  count_lengths_loop(lengths, empty_counts())
}

fn empty_counts() -> List(Int) {
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
}

fn count_lengths_loop(lengths: List(Int), counts: List(Int)) -> List(Int) {
  case lengths {
    [] -> counts
    [0, ..rest] -> count_lengths_loop(rest, counts)
    [length, ..rest] ->
      count_lengths_loop(
        rest,
        set_index(counts, length, list_get(counts, length, 0) + 1),
      )
  }
}

fn validate_counts(
  counts: List(Int),
  index: Int,
  available: Int,
  total: Int,
) -> Result(Int, error.CodecError) {
  case index > max_bits {
    True -> {
      case total > 1 && available > 0 {
        True ->
          Error(error.CodecInvalidData(
            message: "incomplete Huffman code lengths",
          ))
        False -> Ok(total)
      }
    }
    False -> {
      let used = list_get(counts, index, 0)
      case used > available {
        True ->
          Error(error.CodecInvalidData(
            message: "over-subscribed Huffman code lengths",
          ))
        False ->
          validate_counts(
            counts,
            index + 1,
            2 * { available - used },
            total + used,
          )
      }
    }
  }
}

fn sort_symbols_by_length(lengths: List(Int), counts: List(Int)) -> List(Int) {
  let offsets = build_offsets(counts, 0, 1, [])
  let pairs = enumerate_lengths(lengths, 0, [])
  // For each length L (1..15), append the symbols (in input order) with
  // that length.  This produces symbols sorted first by length, then by
  // symbol number, which matches the canonical Huffman ordering.
  let _ = offsets
  bucket_sort_symbols(pairs, 1, [])
}

fn build_offsets(
  counts: List(Int),
  cumulative: Int,
  index: Int,
  acc: List(Int),
) -> List(Int) {
  case index > max_bits {
    True -> list.reverse(acc)
    False -> {
      let used = list_get(counts, index, 0)
      build_offsets(counts, cumulative + used, index + 1, [cumulative, ..acc])
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
    [length, ..rest] ->
      enumerate_lengths(rest, index + 1, [#(index, length), ..acc])
  }
}

fn bucket_sort_symbols(
  pairs: List(#(Int, Int)),
  length: Int,
  acc: List(Int),
) -> List(Int) {
  case length > max_bits {
    True -> list.reverse(acc)
    False -> {
      let bucket =
        list.filter_map(pairs, fn(pair) {
          case pair.1 == length {
            True -> Ok(pair.0)
            False -> Error(Nil)
          }
        })
      bucket_sort_symbols(pairs, length + 1, prepend_reversed(bucket, acc))
    }
  }
}

fn prepend_reversed(values: List(Int), acc: List(Int)) -> List(Int) {
  case values {
    [] -> acc
    [head, ..rest] -> prepend_reversed(rest, [head, ..acc])
  }
}

fn decode_symbol(
  reader: Reader,
  tree: Tree,
) -> Result(#(Int, Reader), error.CodecError) {
  decode_symbol_loop(reader, tree, 1, 0, 0)
}

fn decode_symbol_loop(
  reader: Reader,
  tree: Tree,
  length: Int,
  base: Int,
  offset: Int,
) -> Result(#(Int, Reader), error.CodecError) {
  case length > max_bits {
    True ->
      Error(error.CodecInvalidData(message: "invalid Huffman code (overlong)"))
    False -> {
      use #(bit, reader) <- result.try(read_bits(reader, 1))
      let offset = 2 * offset + bit
      let count = list_get(tree.counts, length, 0)
      case offset < count {
        True -> Ok(#(list_get(tree.symbols, base + offset, -1), reader))
        False ->
          decode_symbol_loop(
            reader,
            tree,
            length + 1,
            base + count,
            offset - count,
          )
      }
    }
  }
}

// -- inflate driver ------------------------------------------------------

fn inflate(
  reader: Reader,
  output: BitArray,
  limits: limit.Limits,
) -> Result(#(BitArray, Reader), error.CodecError) {
  use #(bfinal, reader) <- result.try(read_bits(reader, 1))
  use #(btype, reader) <- result.try(read_bits(reader, 2))

  use #(output, reader) <- result.try(case btype {
    0 -> inflate_stored(reader, output, limits)
    1 -> inflate_fixed(reader, output, limits)
    2 -> inflate_dynamic(reader, output, limits)
    _ -> Error(error.CodecInvalidData(message: "reserved DEFLATE block type"))
  })

  case bfinal {
    1 -> Ok(#(output, reader))
    _ -> inflate(reader, output, limits)
  }
}

fn inflate_stored(
  reader: Reader,
  output: BitArray,
  limits: limit.Limits,
) -> Result(#(BitArray, Reader), error.CodecError) {
  let reader = skip_to_byte_boundary(reader)
  use #(length, reader) <- result.try(read_bits(reader, 16))
  use #(invlength, reader) <- result.try(read_bits(reader, 16))
  use <- bool.guard(
    when: int.bitwise_and(int.bitwise_exclusive_or(length, invlength), 0xFFFF)
      != 0xFFFF,
    return: Error(error.CodecInvalidData(
      message: "stored block length mismatch",
    )),
  )

  use #(bytes, reader) <- result.try(read_raw_bytes(reader, length))
  use new_output <- result.try(append_with_limit(output, bytes, limits))
  Ok(#(new_output, reader))
}

fn read_raw_bytes(
  reader: Reader,
  length: Int,
) -> Result(#(BitArray, Reader), error.CodecError) {
  case length {
    0 -> Ok(#(<<>>, reader))
    _ ->
      case reader.source {
        <<chunk:bytes-size(length), rest:bytes>> ->
          Ok(#(chunk, Reader(buffer: 0, bits: 0, source: rest, overflow: False)))
        _ -> Error(error.CodecInvalidData(message: "truncated stored block"))
      }
  }
}

fn inflate_fixed(
  reader: Reader,
  output: BitArray,
  limits: limit.Limits,
) -> Result(#(BitArray, Reader), error.CodecError) {
  inflate_huffman_block(
    reader,
    output,
    fixed_literal_tree(),
    fixed_distance_tree(),
    limits,
  )
}

fn inflate_dynamic(
  reader: Reader,
  output: BitArray,
  limits: limit.Limits,
) -> Result(#(BitArray, Reader), error.CodecError) {
  use #(hlit_raw, reader) <- result.try(read_bits(reader, 5))
  let hlit = hlit_raw + 257
  use #(hdist_raw, reader) <- result.try(read_bits(reader, 5))
  let hdist = hdist_raw + 1
  use #(hclen_raw, reader) <- result.try(read_bits(reader, 4))
  let hclen = hclen_raw + 4

  use <- bool.guard(
    when: hlit > 286 || hdist > 30,
    return: Error(error.CodecInvalidData(message: "dynamic header out of range")),
  )

  use #(clcl_table, reader) <- result.try(read_code_length_table(reader, hclen))
  use clcl_tree <- result.try(build_tree(clcl_table))

  use #(lit_lengths, dist_lengths, reader) <- result.try(decode_dynamic_lengths(
    reader,
    clcl_tree,
    hlit,
    hdist,
  ))

  use <- bool.guard(
    when: list_get(lit_lengths, 256, 0) == 0,
    return: Error(error.CodecInvalidData(
      message: "dynamic header missing end-of-block symbol",
    )),
  )

  use ltree <- result.try(build_tree(lit_lengths))
  use dtree <- result.try(build_tree(dist_lengths))
  inflate_huffman_block(reader, output, ltree, dtree, limits)
}

fn read_code_length_table(
  reader: Reader,
  count: Int,
) -> Result(#(List(Int), Reader), error.CodecError) {
  read_code_lengths_loop(reader, count, 0, empty_clcl_table())
}

fn empty_clcl_table() -> List(Int) {
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
}

fn code_length_order() -> List(Int) {
  [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
}

fn read_code_lengths_loop(
  reader: Reader,
  remaining: Int,
  index: Int,
  acc: List(Int),
) -> Result(#(List(Int), Reader), error.CodecError) {
  case remaining {
    0 -> Ok(#(acc, reader))
    _ -> {
      use #(value, reader) <- result.try(read_bits(reader, 3))
      let slot = list_get(code_length_order(), index, 0)
      read_code_lengths_loop(
        reader,
        remaining - 1,
        index + 1,
        set_index(acc, slot, value),
      )
    }
  }
}

fn decode_dynamic_lengths(
  reader: Reader,
  tree: Tree,
  hlit: Int,
  hdist: Int,
) -> Result(#(List(Int), List(Int), Reader), error.CodecError) {
  let total = hlit + hdist
  use #(combined, reader) <- result.try(decode_length_run(
    reader,
    tree,
    total,
    0,
    [],
    0,
  ))
  let lit_lengths = pad_to_length(list.take(combined, hlit), 286)
  let dist_lengths = pad_to_length(list.drop(combined, hlit), 30)
  Ok(#(lit_lengths, dist_lengths, reader))
}

fn decode_length_run(
  reader: Reader,
  tree: Tree,
  total: Int,
  produced: Int,
  acc: List(Int),
  previous: Int,
) -> Result(#(List(Int), Reader), error.CodecError) {
  case produced >= total {
    True -> Ok(#(list.reverse(acc), reader))
    False -> {
      use #(symbol, reader) <- result.try(decode_symbol(reader, tree))
      use <- bool.guard(
        when: symbol > 18 || symbol < 0,
        return: Error(error.CodecInvalidData(
          message: "invalid code-length symbol",
        )),
      )

      case symbol {
        n if n < 16 ->
          decode_length_run(reader, tree, total, produced + 1, [n, ..acc], n)
        16 -> {
          use #(extra, reader) <- result.try(read_bits(reader, 2))
          let count = 3 + extra
          use <- bool.guard(
            when: produced == 0,
            return: Error(error.CodecInvalidData(
              message: "repeat-previous symbol at start of run",
            )),
          )
          use <- bool.guard(
            when: produced + count > total,
            return: Error(error.CodecInvalidData(
              message: "code-length run exceeds declared total",
            )),
          )
          let updated = repeat_value(previous, count, acc)
          decode_length_run(
            reader,
            tree,
            total,
            produced + count,
            updated,
            previous,
          )
        }
        17 -> {
          use #(extra, reader) <- result.try(read_bits(reader, 3))
          let count = 3 + extra
          use <- bool.guard(
            when: produced + count > total,
            return: Error(error.CodecInvalidData(
              message: "zero-run symbol exceeds declared total",
            )),
          )
          let updated = repeat_value(0, count, acc)
          decode_length_run(reader, tree, total, produced + count, updated, 0)
        }
        _ -> {
          use #(extra, reader) <- result.try(read_bits(reader, 7))
          let count = 11 + extra
          use <- bool.guard(
            when: produced + count > total,
            return: Error(error.CodecInvalidData(
              message: "long zero-run exceeds declared total",
            )),
          )
          let updated = repeat_value(0, count, acc)
          decode_length_run(reader, tree, total, produced + count, updated, 0)
        }
      }
    }
  }
}

fn repeat_value(value: Int, count: Int, acc: List(Int)) -> List(Int) {
  case count {
    0 -> acc
    _ -> repeat_value(value, count - 1, [value, ..acc])
  }
}

fn pad_to_length(values: List(Int), target: Int) -> List(Int) {
  let current = list.length(values)
  case current >= target {
    True -> values
    False -> list.append(values, repeat_value(0, target - current, []))
  }
}

fn inflate_huffman_block(
  reader: Reader,
  output: BitArray,
  ltree: Tree,
  dtree: Tree,
  limits: limit.Limits,
) -> Result(#(BitArray, Reader), error.CodecError) {
  use #(symbol, reader) <- result.try(decode_symbol(reader, ltree))

  case symbol {
    s if s < 256 -> {
      use new_output <- result.try(append_with_limit(output, <<s>>, limits))
      inflate_huffman_block(reader, new_output, ltree, dtree, limits)
    }
    256 -> Ok(#(output, reader))
    s ->
      case s > max_length_code {
        True ->
          Error(error.CodecInvalidData(
            message: "literal/length code out of range",
          ))
        False -> {
          let length_index = s - 257
          let extra_bits = list_get(length_extra_bits(), length_index, 0)
          let base = list_get(length_base(), length_index, 0)
          use #(extra, reader) <- result.try(read_bits(reader, extra_bits))
          let length = base + extra

          use #(dist_symbol, reader) <- result.try(decode_symbol(reader, dtree))
          use <- bool.guard(
            when: dist_symbol > max_distance_code,
            return: Error(error.CodecInvalidData(
              message: "distance code out of range",
            )),
          )
          let dist_extra_bits = list_get(distance_extra_bits(), dist_symbol, 0)
          let dist_base = list_get(distance_base(), dist_symbol, 0)
          use #(dist_extra, reader) <- result.try(read_bits(
            reader,
            dist_extra_bits,
          ))
          let distance = dist_base + dist_extra

          use new_output <- result.try(apply_backref(
            output,
            distance,
            length,
            limits,
          ))
          inflate_huffman_block(reader, new_output, ltree, dtree, limits)
        }
      }
  }
}

fn apply_backref(
  output: BitArray,
  distance: Int,
  length: Int,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  let size = bit_array.byte_size(output)
  use <- bool.guard(
    when: distance <= 0 || distance > size,
    return: Error(error.CodecInvalidData(message: "back-reference out of range")),
  )

  case distance >= length {
    True -> {
      let assert Ok(chunk) = bit_array.slice(output, size - distance, length)
      append_with_limit(output, chunk, limits)
    }
    False -> apply_backref_byte_by_byte(output, distance, length, limits)
  }
}

fn apply_backref_byte_by_byte(
  output: BitArray,
  distance: Int,
  length: Int,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  case length {
    0 -> Ok(output)
    _ -> {
      let size = bit_array.byte_size(output)
      let assert Ok(byte_slice) = bit_array.slice(output, size - distance, 1)
      use new_output <- result.try(append_with_limit(output, byte_slice, limits))
      apply_backref_byte_by_byte(new_output, distance, length - 1, limits)
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
        value: projected,
      ))
    False -> Ok(bit_array.concat([output, chunk]))
  }
}

// -- fixed huffman tables -----------------------------------------------

fn fixed_literal_tree() -> Tree {
  let lengths = build_fixed_literal_lengths()
  // Reusing the canonical builder keeps the symbol order consistent
  // with dynamically-built trees.
  let assert Ok(tree) = build_tree(lengths)
  tree
}

fn fixed_distance_tree() -> Tree {
  let lengths = list.repeat(5, 32)
  let assert Ok(tree) = build_tree(lengths)
  tree
}

fn build_fixed_literal_lengths() -> List(Int) {
  // 0..143:   length 8
  // 144..255: length 9
  // 256..279: length 7
  // 280..287: length 8
  list.flatten([
    list.repeat(8, 144),
    list.repeat(9, 112),
    list.repeat(7, 24),
    list.repeat(8, 8),
  ])
}

// -- DEFLATE length/distance tables -------------------------------------

fn length_extra_bits() -> List(Int) {
  [
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    1,
    1,
    1,
    1,
    2,
    2,
    2,
    2,
    3,
    3,
    3,
    3,
    4,
    4,
    4,
    4,
    5,
    5,
    5,
    5,
    0,
  ]
}

fn length_base() -> List(Int) {
  [
    3,
    4,
    5,
    6,
    7,
    8,
    9,
    10,
    11,
    13,
    15,
    17,
    19,
    23,
    27,
    31,
    35,
    43,
    51,
    59,
    67,
    83,
    99,
    115,
    131,
    163,
    195,
    227,
    258,
  ]
}

fn distance_extra_bits() -> List(Int) {
  [
    0,
    0,
    0,
    0,
    1,
    1,
    2,
    2,
    3,
    3,
    4,
    4,
    5,
    5,
    6,
    6,
    7,
    7,
    8,
    8,
    9,
    9,
    10,
    10,
    11,
    11,
    12,
    12,
    13,
    13,
  ]
}

fn distance_base() -> List(Int) {
  [
    1,
    2,
    3,
    4,
    5,
    7,
    9,
    13,
    17,
    25,
    33,
    49,
    65,
    97,
    129,
    193,
    257,
    385,
    513,
    769,
    1025,
    1537,
    2049,
    3073,
    4097,
    6145,
    8193,
    12_289,
    16_385,
    24_577,
  ]
}

// -- encoder -------------------------------------------------------------

fn encode_stored(bytes: BitArray) -> BitArray {
  let size = bit_array.byte_size(bytes)
  case size {
    0 -> empty_stored_block()
    _ -> encode_stored_blocks(bytes, size, 0, [])
  }
}

fn empty_stored_block() -> BitArray {
  <<1, 0, 0, 0xFF, 0xFF>>
}

fn encode_stored_blocks(
  source: BitArray,
  remaining: Int,
  written: Int,
  acc: List(BitArray),
) -> BitArray {
  case remaining {
    0 -> bit_array.concat(list.reverse(acc))
    _ -> {
      let chunk_size = case remaining > stored_block_max {
        True -> stored_block_max
        False -> remaining
      }
      let final_flag = case chunk_size == remaining {
        True -> 1
        False -> 0
      }
      let assert Ok(chunk) = bit_array.slice(source, written, chunk_size)
      let header = <<
        final_flag,
        chunk_size:size(16)-little,
        int.bitwise_exclusive_or(chunk_size, 0xFFFF):size(16)-little,
      >>
      encode_stored_blocks(
        source,
        remaining - chunk_size,
        written + chunk_size,
        [bit_array.concat([header, chunk]), ..acc],
      )
    }
  }
}

// -- small list helpers --------------------------------------------------

fn list_get(values: List(Int), index: Int, default: Int) -> Int {
  case index < 0 {
    True -> default
    False -> list_get_loop(values, index, default)
  }
}

fn list_get_loop(values: List(Int), index: Int, default: Int) -> Int {
  case values, index {
    [], _ -> default
    [head, ..], 0 -> head
    [_, ..rest], _ -> list_get_loop(rest, index - 1, default)
  }
}

fn set_index(values: List(Int), index: Int, value: Int) -> List(Int) {
  set_index_loop(values, index, value, [])
}

fn set_index_loop(
  values: List(Int),
  index: Int,
  value: Int,
  acc: List(Int),
) -> List(Int) {
  case values, index {
    [], 0 -> list.reverse([value, ..acc])
    [], n -> set_index_loop([], n - 1, value, [0, ..acc])
    [_, ..rest], 0 -> list.reverse([value, ..acc]) |> list.append(rest)
    [head, ..rest], n -> set_index_loop(rest, n - 1, value, [head, ..acc])
  }
}
