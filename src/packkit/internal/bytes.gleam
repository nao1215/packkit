//// Byte helpers shared by the codec and archive implementations.

import gleam/bit_array
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
