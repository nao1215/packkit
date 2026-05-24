//// Huffman literal decoder for Zstandard's
//// Compressed_Literals_Block (RFC 8478 §4.2.1).
////
//// Initial scope: direct-weight tree description
//// (`header_byte >= 128`) and single-bitstream form.  Once this
//// foundation is stable the FSE-weight form and the 4-stream
//// jump-table form can be layered on top without touching the
//// Huffman table builder or the bitstream walker.
////
//// References:
//// * RFC 8478 §4.2.1 (zstd specification).
//// * `doc/reference/zstd/lib/common/entropy_common.c`
////   `HUF_readStats_body` (0BSD) — consulted to confirm the
////   implied-last-weight balance formula.  The implementation
////   here is written from the spec; the reference is used to
////   verify edge cases such as the `tableLog =
////   highBit(weightTotal) + 1` step and the "rest must be a
////   power of 2" invariant.

import gleam/bit_array
import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/order
import gleam/result
import packkit/internal/fse

/// Errors that can surface while decoding a Huffman literal block.
pub type HufError {
  HufTruncated(message: String)
  HufInvalidWeights(message: String)
  HufBitstreamError(reason: fse.FseError)
  HufUnsupported(feature: String)
}

/// One parsed Huffman tree.  `max_bits` is the canonical Huffman
/// table depth (`tableLog` in the reference).  `lookup` is a flat
/// decoding table of size `2^max_bits` whose entries are
/// `#(symbol, code_length)`.
pub type Tree {
  Tree(max_bits: Int, lookup: dict.Dict(Int, #(Int, Int)))
}

/// Parse the Huffman tree description starting at the first byte
/// of `bytes`.  Returns the parsed tree plus the number of input
/// bytes consumed so the caller can locate the start of the
/// bitstream region that follows.
pub fn read_tree(bytes: BitArray) -> Result(#(Tree, Int), HufError) {
  case bytes {
    <<header_byte, rest:bytes>> ->
      case header_byte >= 128 {
        True -> read_direct_weights(header_byte, rest)
        False -> read_fse_weights(header_byte, rest)
      }
    _ -> Error(HufTruncated(message: "huf: tree description header missing"))
  }
}

fn read_direct_weights(
  header_byte: Int,
  rest: BitArray,
) -> Result(#(Tree, Int), HufError) {
  let num_symbols = header_byte - 127
  let weights_byte_count = { num_symbols + 1 } / 2
  case bit_array.slice(rest, 0, weights_byte_count) {
    Error(_) ->
      Error(HufTruncated(message: "huf: direct-weight body truncated"))
    Ok(weights_bits) -> {
      let weights = unpack_direct_weights(weights_bits, num_symbols, [])
      use tree <- result.try(build_tree(weights))
      Ok(#(tree, 1 + weights_byte_count))
    }
  }
}

fn unpack_direct_weights(
  bytes: BitArray,
  remaining: Int,
  acc: List(Int),
) -> List(Int) {
  case bytes, remaining {
    _, 0 -> list.reverse(acc)
    <<byte, _:bytes>>, 1 -> {
      // Odd symbol count: the trailing low nibble is padding.
      let high = int.bitwise_shift_right(byte, 4)
      list.reverse([high, ..acc])
    }
    <<byte, rest:bytes>>, _ -> {
      let high = int.bitwise_shift_right(byte, 4)
      let low = int.bitwise_and(byte, 0x0F)
      unpack_direct_weights(rest, remaining - 2, [low, high, ..acc])
    }
    _, _ -> list.reverse(acc)
  }
}

fn build_tree(weights: List(Int)) -> Result(Tree, HufError) {
  case weights_with_implied_last(weights) {
    Error(_) -> Error(HufInvalidWeights(message: "huf: invalid weight stream"))
    Ok(#(all_weights, max_bits)) -> {
      let lookup = build_lookup_table(all_weights, max_bits)
      Ok(Tree(max_bits: max_bits, lookup: lookup))
    }
  }
}

fn weights_with_implied_last(
  weights: List(Int),
) -> Result(#(List(Int), Int), Nil) {
  let weight_total = sum_powers(weights, 0)
  case weight_total {
    0 -> Error(Nil)
    _ -> {
      let max_bits = high_bit(weight_total) + 1
      let total = int.bitwise_shift_left(1, max_bits)
      let rest = total - weight_total
      case rest > 0 && int.bitwise_shift_left(1, high_bit(rest)) == rest {
        False -> Error(Nil)
        True -> {
          let last_weight = high_bit(rest) + 1
          Ok(#(list.append(weights, [last_weight]), max_bits))
        }
      }
    }
  }
}

fn sum_powers(weights: List(Int), acc: Int) -> Int {
  case weights {
    [] -> acc
    [0, ..rest] -> sum_powers(rest, acc)
    [w, ..rest] -> sum_powers(rest, acc + int.bitwise_shift_left(1, w - 1))
  }
}

fn high_bit(value: Int) -> Int {
  high_bit_loop(value, -1)
}

fn high_bit_loop(value: Int, acc: Int) -> Int {
  case value {
    0 -> acc
    _ -> high_bit_loop(int.bitwise_shift_right(value, 1), acc + 1)
  }
}

fn build_lookup_table(
  weights: List(Int),
  max_bits: Int,
) -> dict.Dict(Int, #(Int, Int)) {
  // 1. Pair each symbol with its code length (max_bits + 1 - weight).
  let with_bits =
    list.index_fold(weights, [], fn(acc, weight, symbol) {
      case weight {
        0 -> acc
        _ -> [#(symbol, max_bits + 1 - weight), ..acc]
      }
    })
    |> list.reverse
  // 2. Sort by (bits ascending, symbol ascending) — the canonical
  //    Huffman ordering.
  let sorted =
    list.sort(with_bits, fn(a, b) {
      let #(sym_a, bits_a) = a
      let #(sym_b, bits_b) = b
      case int.compare(bits_a, bits_b) {
        order.Eq -> int.compare(sym_a, sym_b)
        other -> other
      }
    })
  // 3. Each symbol with `bits` code length occupies 2^(max_bits-bits)
  //    consecutive lookup slots starting from the next available
  //    code, so the high `bits` bits of any matching bitstream
  //    prefix hit one of those slots.
  fill_lookup(sorted, max_bits, 0, dict.new())
}

fn fill_lookup(
  sorted: List(#(Int, Int)),
  max_bits: Int,
  next_code: Int,
  acc: dict.Dict(Int, #(Int, Int)),
) -> dict.Dict(Int, #(Int, Int)) {
  case sorted {
    [] -> acc
    [#(sym, bits), ..rest] -> {
      let span = int.bitwise_shift_left(1, max_bits - bits)
      let updated = fill_span(acc, next_code, span, sym, bits)
      fill_lookup(rest, max_bits, next_code + span, updated)
    }
  }
}

fn fill_span(
  acc: dict.Dict(Int, #(Int, Int)),
  start: Int,
  span: Int,
  sym: Int,
  bits: Int,
) -> dict.Dict(Int, #(Int, Int)) {
  case span {
    0 -> acc
    _ ->
      fill_span(
        dict.insert(acc, start, #(sym, bits)),
        start + 1,
        span - 1,
        sym,
        bits,
      )
  }
}

/// Decode `num_symbols` symbols from one zstd Huffman bitstream.
/// The bitstream's last byte holds the stream marker (highest set
/// bit) followed by the most-recent decoded bit; the reader walks
/// from the end backward in MSB-first order.
pub fn decode_stream(
  tree: Tree,
  bytes: BitArray,
  num_symbols: Int,
) -> Result(BitArray, HufError) {
  use reader <- result.try(
    fse.new_backward_reader(bytes)
    |> result.map_error(HufBitstreamError),
  )
  decode_symbols_loop(tree, reader, num_symbols, <<>>)
}

fn decode_symbols_loop(
  tree: Tree,
  reader: fse.BackwardReader,
  remaining: Int,
  acc: BitArray,
) -> Result(BitArray, HufError) {
  case remaining {
    0 -> Ok(acc)
    _ -> decode_one_symbol(tree, reader, remaining, acc)
  }
}

/// Decode a 4-stream Huffman literal block.  The compressed
/// region begins with a 6-byte jump table — three little-endian
/// 16-bit sizes for streams 1, 2, 3 — followed by the four
/// bitstream segments concatenated.  Stream 4's size is whatever
/// remains after the first three plus the jump table itself.
///
/// The total decoded output equals the catenation of each
/// stream's output, in order 1, 2, 3, 4.  Each stream emits
/// roughly `regenerated_size / 4` symbols; the last stream covers
/// any rounding remainder.
pub fn decode_four_streams(
  tree: Tree,
  bytes: BitArray,
  regenerated_size: Int,
) -> Result(BitArray, HufError) {
  let total = bit_array.byte_size(bytes)
  case total < 6 {
    True -> Error(HufTruncated(message: "huf: 4-stream jump table truncated"))
    False ->
      case bytes {
        <<
          size1:size(16)-little,
          size2:size(16)-little,
          size3:size(16)-little,
          streams:bytes,
        >> -> {
          let body_size = total - 6
          let size4 = body_size - size1 - size2 - size3
          use <- bool.guard(
            when: size4 < 0,
            return: Error(HufInvalidWeights(
              message: "huf: 4-stream jump table sums past body",
            )),
          )
          // RFC 8478 §4.2.1.3: each of the first three streams
          // decodes ceil(regenerated_size / 4) symbols; the
          // fourth covers the remainder.
          let per_stream = { regenerated_size + 3 } / 4
          let stream4_size = regenerated_size - per_stream * 3
          decode_split_streams(tree, streams, #(size1, size2, size3, size4), #(
            per_stream,
            per_stream,
            per_stream,
            stream4_size,
          ))
        }
        _ -> Error(HufTruncated(message: "huf: 4-stream header malformed"))
      }
  }
}

fn decode_split_streams(
  tree: Tree,
  streams: BitArray,
  byte_sizes: #(Int, Int, Int, Int),
  symbol_counts: #(Int, Int, Int, Int),
) -> Result(BitArray, HufError) {
  let #(b1, b2, b3, b4) = byte_sizes
  let #(c1, c2, c3, c4) = symbol_counts
  use s1 <- result.try(slice_stream(streams, 0, b1))
  use s2 <- result.try(slice_stream(streams, b1, b2))
  use s3 <- result.try(slice_stream(streams, b1 + b2, b3))
  use s4 <- result.try(slice_stream(streams, b1 + b2 + b3, b4))
  use o1 <- result.try(decode_stream(tree, s1, c1))
  use o2 <- result.try(decode_stream(tree, s2, c2))
  use o3 <- result.try(decode_stream(tree, s3, c3))
  use o4 <- result.try(decode_stream(tree, s4, c4))
  Ok(bit_array.concat([o1, o2, o3, o4]))
}

fn slice_stream(
  bytes: BitArray,
  offset: Int,
  length: Int,
) -> Result(BitArray, HufError) {
  case bit_array.slice(bytes, offset, length) {
    Ok(value) -> Ok(value)
    Error(_) -> Error(HufTruncated(message: "huf: stream slice out of range"))
  }
}

fn read_fse_weights(
  i_size: Int,
  rest: BitArray,
) -> Result(#(Tree, Int), HufError) {
  // i_size bytes follow the header byte; they hold an FSE-encoded
  // weight stream.  The forward bitstream begins with a
  // distribution header (accuracy_log + per-symbol counts) and is
  // followed by the backward bitstream containing the two
  // interleaved FSE states.
  case bit_array.slice(rest, 0, i_size) {
    Error(_) -> Error(HufTruncated(message: "huf: FSE-weight body truncated"))
    Ok(fse_bytes) -> {
      use weights <- result.try(decode_fse_weight_stream(fse_bytes))
      use tree <- result.try(build_tree(weights))
      Ok(#(tree, 1 + i_size))
    }
  }
}

const max_huff_log: Int = 12

fn decode_fse_weight_stream(bytes: BitArray) -> Result(List(Int), HufError) {
  // The weight FSE table caps accuracy_log at 6 and the weight
  // alphabet at HUF_TABLELOG_MAX = 12.
  use #(counts, accuracy_log, after_header) <- result.try(read_distribution(
    bytes,
    6,
    max_huff_log,
  ))
  let table = fse.build_state_table(counts, accuracy_log)
  use reader <- result.try(
    fse.new_backward_reader(after_header)
    |> result.map_error(HufBitstreamError),
  )
  use #(state_a, reader) <- result.try(
    fse.read_backward_bits(reader, accuracy_log)
    |> result.map_error(HufBitstreamError),
  )
  use #(state_b, reader) <- result.try(
    fse.read_backward_bits(reader, accuracy_log)
    |> result.map_error(HufBitstreamError),
  )
  decode_fse_weight_pairs(table, reader, state_a, state_b, True, [])
}

fn decode_fse_weight_pairs(
  table: dict.Dict(Int, fse.StateEntry),
  reader: fse.BackwardReader,
  state_a: Int,
  state_b: Int,
  use_a: Bool,
  acc: List(Int),
) -> Result(List(Int), HufError) {
  let active_state = case use_a {
    True -> state_a
    False -> state_b
  }
  fse.decode_state(table, active_state, reader)
  |> finish_or_continue_weight_pair(
    table,
    state_a,
    state_b,
    use_a,
    acc,
    active_state,
  )
}

fn finish_or_continue_weight_pair(
  decode_outcome: Result(#(Int, Int, fse.BackwardReader), fse.FseError),
  table: dict.Dict(Int, fse.StateEntry),
  state_a: Int,
  state_b: Int,
  use_a: Bool,
  acc: List(Int),
  active_state: Int,
) -> Result(List(Int), HufError) {
  case decode_outcome {
    // The bitstream ran out while reading the bits that would
    // have updated the active state.  Per RFC 8478 the FSE
    // weight stream emits the partner's symbol followed by the
    // active state's symbol without consuming further bits.
    // Exhaustion is the normal stop signal for the weight
    // stream so both FSE error variants are handled identically.
    Error(fse.FseTruncated) | Error(fse.FseEmptyBitstream) -> {
      let partner = case use_a {
        True -> state_b
        False -> state_a
      }
      let active_symbol = lookup_symbol(table, active_state)
      let partner_symbol = lookup_symbol(table, partner)
      Ok(list.reverse([partner_symbol, active_symbol, ..acc]))
    }
    Ok(#(symbol, next_state, new_reader)) -> {
      let #(next_a, next_b) = case use_a {
        True -> #(next_state, state_b)
        False -> #(state_a, next_state)
      }
      decode_fse_weight_pairs(table, new_reader, next_a, next_b, !use_a, [
        symbol,
        ..acc
      ])
    }
  }
}

fn lookup_symbol(table: dict.Dict(Int, fse.StateEntry), state: Int) -> Int {
  dict.get(table, state)
  |> result.map(fn(entry) { entry.symbol })
  |> result.unwrap(0)
}

// -- forward bit reader + FSE distribution parser ----------------------
//
// Duplicated from `packkit/zstd.gleam` to keep this module
// independent of the high-level zstd codec.  A future refactor
// could move the shared FSE distribution parsing into
// `packkit/internal/fse` and have both callers reuse it.

type FwdBitReader {
  FwdBitReader(
    bytes: BitArray,
    buffer: Int,
    bits_in_buffer: Int,
    bits_consumed: Int,
  )
}

fn new_fwd_reader(bytes: BitArray) -> FwdBitReader {
  FwdBitReader(bytes: bytes, buffer: 0, bits_in_buffer: 0, bits_consumed: 0)
}

fn fwd_refill(reader: FwdBitReader, needed: Int) -> FwdBitReader {
  use <- bool.guard(when: reader.bits_in_buffer >= needed, return: reader)
  case reader.bytes {
    <<byte, rest:bytes>> ->
      fwd_refill(
        FwdBitReader(
          bytes: rest,
          buffer: int.bitwise_or(
            reader.buffer,
            int.bitwise_shift_left(byte, reader.bits_in_buffer),
          ),
          bits_in_buffer: reader.bits_in_buffer + 8,
          bits_consumed: reader.bits_consumed,
        ),
        needed,
      )
    _ -> reader
  }
}

fn fwd_peek(reader: FwdBitReader, count: Int) -> #(Int, FwdBitReader) {
  let refilled = fwd_refill(reader, count)
  let mask = int.bitwise_shift_left(1, count) - 1
  #(int.bitwise_and(refilled.buffer, mask), refilled)
}

fn fwd_drop(reader: FwdBitReader, count: Int) -> FwdBitReader {
  let refilled = fwd_refill(reader, count)
  case refilled.bits_in_buffer >= count {
    True ->
      FwdBitReader(
        bytes: refilled.bytes,
        buffer: int.bitwise_shift_right(refilled.buffer, count),
        bits_in_buffer: refilled.bits_in_buffer - count,
        bits_consumed: refilled.bits_consumed + count,
      )
    False -> refilled
  }
}

fn fwd_read(
  reader: FwdBitReader,
  count: Int,
) -> Result(#(Int, FwdBitReader), HufError) {
  let refilled = fwd_refill(reader, count)
  case refilled.bits_in_buffer >= count {
    False -> Error(HufTruncated(message: "huf: FSE distribution truncated"))
    True -> {
      let #(value, peeked) = fwd_peek(refilled, count)
      Ok(#(value, fwd_drop(peeked, count)))
    }
  }
}

fn read_distribution(
  bytes: BitArray,
  max_accuracy_log: Int,
  max_symbol: Int,
) -> Result(#(List(Int), Int, BitArray), HufError) {
  let reader = new_fwd_reader(bytes)
  use #(low4, reader) <- result.try(fwd_read(reader, 4))
  let accuracy_log = low4 + 5
  case accuracy_log > max_accuracy_log {
    True ->
      Error(HufInvalidWeights(
        message: "huf: FSE distribution accuracy_log too high",
      ))
    False -> {
      let table_size = int.bitwise_shift_left(1, accuracy_log)
      use #(counts, reader) <- result.try(
        decode_distribution_counts(
          reader,
          table_size + 1,
          table_size,
          accuracy_log + 1,
          False,
          0,
          max_symbol,
          [],
        ),
      )
      let bytes_consumed = { reader.bits_consumed + 7 } / 8
      let total = bit_array.byte_size(bytes)
      case bit_array.slice(bytes, bytes_consumed, total - bytes_consumed) {
        Ok(rest) ->
          Ok(#(pad_distribution(counts, max_symbol + 1), accuracy_log, rest))
        Error(_) ->
          Error(HufTruncated(message: "huf: FSE distribution tail truncated"))
      }
    }
  }
}

fn decode_distribution_counts(
  reader: FwdBitReader,
  remaining: Int,
  threshold: Int,
  bit_count: Int,
  previous_is_zero: Bool,
  charnum: Int,
  max_symbol: Int,
  acc: List(Int),
) -> Result(#(List(Int), FwdBitReader), HufError) {
  use <- bool.guard(
    when: !{ remaining > 1 && charnum <= max_symbol },
    return: Ok(#(list.reverse(acc), reader)),
  )
  case previous_is_zero {
    True -> {
      use #(extra, reader) <- result.try(read_zero_repeat(reader, 0))
      let acc = prepend_zeros(extra, acc)
      decode_distribution_counts(
        reader,
        remaining,
        threshold,
        bit_count,
        False,
        charnum + extra,
        max_symbol,
        acc,
      )
    }
    False -> {
      let #(value, reader) = fwd_peek(reader, bit_count)
      let #(count, bits_consumed) =
        split_distribution_count(value, threshold, remaining, bit_count)
      let reader = fwd_drop(reader, bits_consumed)
      let probability = count - 1
      let abs_prob = int.absolute_value(probability)
      let next_remaining = remaining - abs_prob
      let #(next_threshold, next_bit_count) =
        shrink_threshold(threshold, bit_count, next_remaining)
      decode_distribution_counts(
        reader,
        next_remaining,
        next_threshold,
        next_bit_count,
        probability == 0,
        charnum + 1,
        max_symbol,
        [probability, ..acc],
      )
    }
  }
}

fn split_distribution_count(
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

fn shrink_threshold(
  threshold: Int,
  bit_count: Int,
  remaining: Int,
) -> #(Int, Int) {
  use <- bool.guard(when: remaining >= threshold, return: #(
    threshold,
    bit_count,
  ))
  use <- bool.guard(when: threshold <= 1, return: #(threshold, bit_count))
  shrink_threshold(threshold / 2, bit_count - 1, remaining)
}

fn read_zero_repeat(
  reader: FwdBitReader,
  acc: Int,
) -> Result(#(Int, FwdBitReader), HufError) {
  use #(chunk, reader) <- result.try(fwd_read(reader, 2))
  case chunk {
    3 -> read_zero_repeat(reader, acc + 3)
    n -> Ok(#(acc + n, reader))
  }
}

fn prepend_zeros(count: Int, acc: List(Int)) -> List(Int) {
  case count {
    0 -> acc
    _ -> prepend_zeros(count - 1, [0, ..acc])
  }
}

fn pad_distribution(counts: List(Int), target: Int) -> List(Int) {
  let current = list.length(counts)
  case current >= target {
    True -> counts
    False -> list.append(counts, repeat_zeros(target - current, []))
  }
}

fn repeat_zeros(n: Int, acc: List(Int)) -> List(Int) {
  case n {
    0 -> acc
    _ -> repeat_zeros(n - 1, [0, ..acc])
  }
}

// -- end forward bit reader / FSE distribution parser -----------------

fn decode_one_symbol(
  tree: Tree,
  reader: fse.BackwardReader,
  remaining: Int,
  acc: BitArray,
) -> Result(BitArray, HufError) {
  // Peek `max_bits` bits to index the lookup table, then re-consume
  // only the bits that the matched code actually uses.
  use #(index, _) <- result.try(
    fse.read_backward_bits(reader, tree.max_bits)
    |> result.map_error(HufBitstreamError),
  )
  case dict.get(tree.lookup, index) {
    Error(_) ->
      Error(HufInvalidWeights(message: "huf: bitstream index out of table"))
    Ok(#(sym, used_bits)) -> {
      use #(_, reader_consumed) <- result.try(
        fse.read_backward_bits(reader, used_bits)
        |> result.map_error(HufBitstreamError),
      )
      decode_symbols_loop(tree, reader_consumed, remaining - 1, <<
        acc:bits,
        sym,
      >>)
    }
  }
}
