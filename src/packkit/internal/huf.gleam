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
        False ->
          Error(HufUnsupported(feature: "huf: FSE-compressed weight stream"))
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
    Error(_) ->
      Error(HufInvalidWeights(message: "huf: invalid weight stream"))
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
