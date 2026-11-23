//// Byte helpers shared by the codec and archive implementations.

import gleam/bit_array
import gleam/bool
import gleam/list
import gleam/result
import packkit/codec
import packkit/limit

/// Appends `chunk` to `output`, or returns `LimitExceeded` when the result
/// would be larger than `max_output_bytes`.
pub fn append_with_limit(
  output: BitArray,
  chunk: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, codec.CodecError) {
  let projected = bit_array.byte_size(output) + bit_array.byte_size(chunk)
  case projected > limits.max_output_bytes {
    True ->
      Error(codec.LimitExceeded(limit: "max_output_bytes", actual: projected))
    False -> Ok(bit_array.concat([output, chunk]))
  }
}

/// Drops the NUL bytes that pad a fixed-width header field.
pub fn strip_trailing_nul(bytes: BitArray) -> BitArray {
  strip_trailing_nul_loop(bytes, bit_array.byte_size(bytes))
}

fn strip_trailing_nul_loop(bytes: BitArray, size: Int) -> BitArray {
  case bit_array.slice(bytes, size - 1, 1) {
    Ok(<<0>>) -> strip_trailing_nul_loop(bytes, size - 1)
    _ ->
      case bit_array.slice(bytes, 0, size) {
        Ok(kept) -> kept
        Error(Nil) -> <<>>
      }
  }
}

/// Returns `count` copies of `byte`, or an empty bit array when `count` is
/// not positive.
pub fn repeat(byte: Int, count: Int) -> BitArray {
  repeat_loop(byte, count, <<>>)
}

fn repeat_loop(byte: Int, count: Int, acc: BitArray) -> BitArray {
  case count <= 0 {
    True -> acc
    False -> repeat_loop(byte, count - 1, <<acc:bits, byte>>)
  }
}

/// Cuts `value` to `width` bytes, or pads it on the right with `fill`.
pub fn pad_end(value: BitArray, width: Int, fill: Int) -> BitArray {
  case value {
    <<head:bytes-size(width), _:bytes>> -> head
    _ -> <<value:bits, repeat(fill, width - bit_array.byte_size(value)):bits>>
  }
}

/// Splits `bytes` after the first `count` bytes. When `bytes` is shorter,
/// the first part is all of it and the second is empty.
pub fn split_at(bytes: BitArray, count: Int) -> #(BitArray, BitArray) {
  case bytes {
    <<head:bytes-size(count), tail:bytes>> -> #(head, tail)
    _ -> #(bytes, <<>>)
  }
}

/// Appends `length` bytes copied from `distance` bytes back in `output`,
/// as an LZ77 match does. The copy may overlap the bytes it adds, so a
/// distance of 1 repeats the last byte `length` times.
///
/// Returns `InvalidData` when `distance` is not between 1 and the size
/// of `output`, and `LimitExceeded` when the result would be larger than
/// `max_output_bytes`.
pub fn copy_back(
  output: BitArray,
  distance: Int,
  length: Int,
  limits: limit.Limits,
) -> Result(BitArray, codec.CodecError) {
  let size = bit_array.byte_size(output)
  let projected = size + length
  use <- bool.guard(
    when: projected > limits.max_output_bytes,
    return: Error(codec.LimitExceeded(
      limit: "max_output_bytes",
      actual: projected,
    )),
  )
  let out_of_range =
    Error(codec.InvalidData(message: "back-reference distance out of range"))
  use <- bool.guard(
    when: distance <= 0 || distance > size,
    return: out_of_range,
  )
  let start = size - distance
  case output {
    <<_:bytes-size(start), window:bytes>> ->
      Ok(<<output:bits, repeat_window(window, length):bits>>)
    _ -> out_of_range
  }
}

// Doubles `window` until it holds `length` bytes and keeps the first
// `length`. Doubling keeps the period, so this matches a byte-by-byte
// overlapping copy.
fn repeat_window(window: BitArray, length: Int) -> BitArray {
  case window {
    <<head:bytes-size(length), _:bytes>> -> head
    _ -> repeat_window(<<window:bits, window:bits>>, length)
  }
}

/// Builds a bit array from a list of byte values.
pub fn from_list(values: List(Int)) -> BitArray {
  list.fold(values, <<>>, fn(acc, byte) { <<acc:bits, byte>> })
}

/// Builds a bit array from a list of byte values in reverse order, the
/// last byte first.
pub fn from_reversed_list(values: List(Int)) -> BitArray {
  from_list(list.reverse(values))
}

/// Returns the bytes of `bytes` as a list of byte values.
pub fn to_list(bytes: BitArray) -> List(Int) {
  to_list_loop(bytes, [])
}

fn to_list_loop(bytes: BitArray, acc: List(Int)) -> List(Int) {
  case bytes {
    <<byte, rest:bytes>> -> to_list_loop(rest, [byte, ..acc])
    _ -> list.reverse(acc)
  }
}

/// Reports whether every byte is zero. An empty bit array is all zero.
pub fn all_zero(bytes: BitArray) -> Bool {
  case bytes {
    <<0, rest:bytes>> -> all_zero(rest)
    <<>> -> True
    _ -> False
  }
}

/// Splits `bytes` after `count` bytes, or returns `Error(Nil)` when
/// `bytes` is shorter or `count` is negative.
pub fn split(
  bytes: BitArray,
  count: Int,
) -> Result(#(BitArray, BitArray), Nil) {
  use <- bool.guard(when: count < 0, return: Error(Nil))
  case bytes {
    <<head:bytes-size(count), rest:bytes>> -> Ok(#(head, rest))
    _ -> Error(Nil)
  }
}

/// Returns `length` bytes from `offset`, or `Error(Nil)` when they are
/// not all inside `bytes`. Unlike `bit_array.slice` on Erlang, a negative
/// length is an error and does not read backwards.
pub fn slice(
  bytes: BitArray,
  offset: Int,
  length: Int,
) -> Result(BitArray, Nil) {
  use #(_, rest) <- result.try(split(bytes, offset))
  use #(value, _) <- result.try(split(rest, length))
  Ok(value)
}

/// Returns `LimitExceeded` when the compressed input is larger than
/// `max_input_bytes`.
pub fn check_input(
  input: BitArray,
  limits: limit.Limits,
) -> Result(Nil, codec.CodecError) {
  let size = bit_array.byte_size(input)
  case size > limits.max_input_bytes {
    True -> Error(codec.LimitExceeded(limit: "max_input_bytes", actual: size))
    False -> Ok(Nil)
  }
}
