//// Snappy raw-block and framed codec.
////
//// `snappy.raw_decode` and `snappy.raw_encode` operate on the original
//// Snappy block format documented in `snappy-format-description`.
//// `snappy.decode` and `snappy.encode` operate on the streaming
//// framed form (`sNaPpY` stream identifier and chunked layout).  The
//// encoder emits uncompressed-chunk records so any framed-Snappy
//// reader can decompress the output even before a Snappy compressor
//// is added.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/result
import packkit/checksum
import packkit/codec as codecs
import packkit/error
import packkit/limit

const stream_identifier: BitArray = <<
  0xFF, 0x06, 0x00, 0x00, 0x73, 0x4E, 0x61, 0x50, 0x70, 0x59,
>>

const chunk_compressed: Int = 0x00

const chunk_uncompressed: Int = 0x01

const chunk_padding: Int = 0xFE

const chunk_stream_identifier: Int = 0xFF

const max_uncompressed_chunk: Int = 65_536

/// Snappy framed codec smart constructor.
pub fn codec() -> codecs.Codec {
  codecs.snappy()
}

/// Encode `bytes` as a framed Snappy stream that stores every chunk
/// in the uncompressed form.
pub fn encode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  let chunks = encode_uncompressed_chunks(bytes, [])
  Ok(bit_array.concat([stream_identifier, chunks]))
}

/// Decode a framed Snappy stream using the default resource limits.
pub fn decode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  decode_with_limits(bytes: bytes, limits: limit.default())
}

/// Decode a framed Snappy stream using explicit resource limits.
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

  case bytes {
    <<0xFF, 0x06, 0x00, 0x00, 0x73, 0x4E, 0x61, 0x50, 0x70, 0x59, rest:bytes>> ->
      decode_chunks(rest, <<>>, limits)
    _ ->
      Error(error.CodecInvalidData(message: "snappy: missing stream identifier"))
  }
}

/// Decode a single Snappy raw block.
pub fn raw_decode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  raw_decode_with_limits(bytes: bytes, limits: limit.default())
}

/// Decode a Snappy raw block using explicit resource limits.
pub fn raw_decode_with_limits(
  bytes bytes: BitArray,
  limits limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  use #(uncompressed_length, after_varint) <- result.try(read_varint(
    bytes,
    0,
    0,
  ))
  use <- bool.guard(
    when: uncompressed_length > limit.max_output_bytes(limits),
    return: Error(error.CodecLimitExceeded(
      limit: "max_output_bytes",
      actual: uncompressed_length,
    )),
  )

  use output <- result.try(decode_raw_loop(after_varint, <<>>, limits))
  case bit_array.byte_size(output) == uncompressed_length {
    True -> Ok(output)
    False ->
      Error(error.CodecInvalidData(
        message: "snappy: raw output length disagrees with declared length",
      ))
  }
}

/// Encode `bytes` as a Snappy raw block by emitting a single literal
/// run covering the entire payload.
pub fn raw_encode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  let length = bit_array.byte_size(bytes)
  let length_varint = write_varint(length)
  let literal = emit_literal(bytes)
  Ok(bit_array.concat([length_varint, literal]))
}

fn encode_uncompressed_chunks(
  remaining: BitArray,
  acc: List(BitArray),
) -> BitArray {
  let total = bit_array.byte_size(remaining)
  case total {
    0 -> bit_array.concat(list.reverse(acc))
    _ -> {
      let chunk_size = case total > max_uncompressed_chunk {
        True -> max_uncompressed_chunk
        False -> total
      }
      let assert Ok(chunk) = bit_array.slice(remaining, 0, chunk_size)
      let assert Ok(after) =
        bit_array.slice(remaining, chunk_size, total - chunk_size)

      let crc = checksum.snappy_mask(crc: checksum.crc32c(data: chunk))
      let payload_size = chunk_size + 4
      let header = <<
        chunk_uncompressed,
        payload_size:size(24)-little,
        crc:size(32)-little,
      >>

      encode_uncompressed_chunks(after, [
        bit_array.concat([header, chunk]),
        ..acc
      ])
    }
  }
}

fn decode_chunks(
  bytes: BitArray,
  output: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  case bytes {
    <<>> -> Ok(output)
    <<chunk_type, length:size(24)-little, rest:bytes>> -> {
      case bit_array.byte_size(rest) < length {
        True ->
          Error(error.CodecInvalidData(
            message: "snappy: chunk payload truncated",
          ))
        False -> {
          let assert Ok(body) = bit_array.slice(rest, 0, length)
          let assert Ok(after) =
            bit_array.slice(rest, length, bit_array.byte_size(rest) - length)

          use new_output <- result.try(case chunk_type {
            t if t == chunk_uncompressed ->
              decode_uncompressed_chunk(body, output, limits)
            t if t == chunk_compressed ->
              decode_compressed_chunk(body, output, limits)
            t if t == chunk_padding -> Ok(output)
            t if t == chunk_stream_identifier ->
              case body == <<0x73, 0x4E, 0x61, 0x50, 0x70, 0x59>> {
                True -> Ok(output)
                False ->
                  Error(error.CodecInvalidData(
                    message: "snappy: repeated stream identifier mismatched",
                  ))
              }
            t if t >= 0x80 -> Ok(output)
            _ ->
              Error(error.CodecInvalidData(
                message: "snappy: unsupported reserved chunk type",
              ))
          })

          decode_chunks(after, new_output, limits)
        }
      }
    }
    _ ->
      Error(error.CodecInvalidData(message: "snappy: chunk header truncated"))
  }
}

fn decode_uncompressed_chunk(
  body: BitArray,
  output: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  case body {
    <<_crc:size(32)-little, data:bytes>> ->
      append_with_limit(output, data, limits)
    _ ->
      Error(error.CodecInvalidData(
        message: "snappy: uncompressed chunk too short",
      ))
  }
}

fn decode_compressed_chunk(
  body: BitArray,
  output: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  case body {
    <<_crc:size(32)-little, payload:bytes>> -> {
      use decoded <- result.try(raw_decode_with_limits(
        bytes: payload,
        limits: limits,
      ))
      append_with_limit(output, decoded, limits)
    }
    _ ->
      Error(error.CodecInvalidData(
        message: "snappy: compressed chunk too short",
      ))
  }
}

fn read_varint(
  bytes: BitArray,
  acc: Int,
  shift: Int,
) -> Result(#(Int, BitArray), error.CodecError) {
  case bytes {
    <<b, rest:bytes>> -> {
      let part = int.bitwise_and(b, 0x7F)
      let acc = int.bitwise_or(acc, int.bitwise_shift_left(part, shift))
      case int.bitwise_and(b, 0x80) {
        0 -> Ok(#(acc, rest))
        _ ->
          case shift > 28 {
            True ->
              Error(error.CodecInvalidData(message: "snappy: oversize varint"))
            False -> read_varint(rest, acc, shift + 7)
          }
      }
    }
    _ ->
      Error(error.CodecInvalidData(message: "snappy: truncated varint length"))
  }
}

fn write_varint(value: Int) -> BitArray {
  write_varint_loop(value, <<>>)
}

fn write_varint_loop(value: Int, acc: BitArray) -> BitArray {
  case value < 0x80 {
    True -> bit_array.concat([acc, <<value>>])
    False -> {
      let low = int.bitwise_and(value, 0x7F)
      let high = int.bitwise_shift_right(value, 7)
      let byte_value = int.bitwise_or(low, 0x80)
      write_varint_loop(high, bit_array.concat([acc, <<byte_value>>]))
    }
  }
}

fn decode_raw_loop(
  bytes: BitArray,
  output: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  case bytes {
    <<>> -> Ok(output)
    <<tag, rest:bytes>> -> {
      let kind = int.bitwise_and(tag, 0x03)
      case kind {
        0 -> handle_literal(tag, rest, output, limits)
        1 -> handle_copy_1(tag, rest, output, limits)
        2 -> handle_copy_2(tag, rest, output, limits)
        _ -> handle_copy_4(tag, rest, output, limits)
      }
    }
    _ -> Error(error.CodecInvalidData(message: "snappy: malformed raw block"))
  }
}

fn handle_literal(
  tag: Int,
  rest: BitArray,
  output: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  let header = int.bitwise_shift_right(tag, 2)
  use #(length, after_extra) <- result.try(case header {
    h if h < 60 -> Ok(#(h + 1, rest))
    60 -> read_literal_extra(rest, 1)
    61 -> read_literal_extra(rest, 2)
    62 -> read_literal_extra(rest, 3)
    _ -> read_literal_extra(rest, 4)
  })

  case bit_array.byte_size(after_extra) < length {
    True ->
      Error(error.CodecInvalidData(message: "snappy: literal run truncated"))
    False -> {
      let assert Ok(chunk) = bit_array.slice(after_extra, 0, length)
      let assert Ok(after) =
        bit_array.slice(
          after_extra,
          length,
          bit_array.byte_size(after_extra) - length,
        )
      use output <- result.try(append_with_limit(output, chunk, limits))
      decode_raw_loop(after, output, limits)
    }
  }
}

fn read_literal_extra(
  rest: BitArray,
  width: Int,
) -> Result(#(Int, BitArray), error.CodecError) {
  case bit_array.byte_size(rest) < width {
    True ->
      Error(error.CodecInvalidData(
        message: "snappy: literal length extension truncated",
      ))
    False -> {
      let assert Ok(prefix) = bit_array.slice(rest, 0, width)
      let assert Ok(after) =
        bit_array.slice(rest, width, bit_array.byte_size(rest) - width)
      let value = read_le(prefix, width)
      Ok(#(value + 1, after))
    }
  }
}

fn read_le(bytes: BitArray, width: Int) -> Int {
  case width, bytes {
    1, <<b>> -> b
    2, <<b1, b2>> -> b1 + b2 * 256
    3, <<b1, b2, b3>> -> b1 + b2 * 256 + b3 * 65_536
    4, <<b1, b2, b3, b4>> -> b1 + b2 * 256 + b3 * 65_536 + b4 * 16_777_216
    _, _ -> 0
  }
}

fn handle_copy_1(
  tag: Int,
  rest: BitArray,
  output: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  case rest {
    <<offset_low, after_offset:bytes>> -> {
      let length = int.bitwise_and(int.bitwise_shift_right(tag, 2), 0x07) + 4
      let offset_high = int.bitwise_and(int.bitwise_shift_right(tag, 5), 0x07)
      let offset =
        int.bitwise_or(int.bitwise_shift_left(offset_high, 8), offset_low)
      apply_copy(after_offset, output, limits, offset, length)
    }
    _ ->
      Error(error.CodecInvalidData(message: "snappy: copy-1 offset truncated"))
  }
}

fn handle_copy_2(
  tag: Int,
  rest: BitArray,
  output: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  case rest {
    <<offset:size(16)-little, after:bytes>> -> {
      let length = int.bitwise_shift_right(tag, 2) + 1
      apply_copy(after, output, limits, offset, length)
    }
    _ ->
      Error(error.CodecInvalidData(message: "snappy: copy-2 offset truncated"))
  }
}

fn handle_copy_4(
  tag: Int,
  rest: BitArray,
  output: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  case rest {
    <<offset:size(32)-little, after:bytes>> -> {
      let length = int.bitwise_shift_right(tag, 2) + 1
      apply_copy(after, output, limits, offset, length)
    }
    _ ->
      Error(error.CodecInvalidData(message: "snappy: copy-4 offset truncated"))
  }
}

fn apply_copy(
  rest: BitArray,
  output: BitArray,
  limits: limit.Limits,
  offset: Int,
  length: Int,
) -> Result(BitArray, error.CodecError) {
  let size = bit_array.byte_size(output)
  use <- bool.guard(
    when: offset <= 0 || offset > size,
    return: Error(error.CodecInvalidData(
      message: "snappy: copy offset out of bounds",
    )),
  )

  use new_output <- result.try(case offset >= length {
    True -> {
      let assert Ok(chunk) = bit_array.slice(output, size - offset, length)
      append_with_limit(output, chunk, limits)
    }
    False -> copy_byte_by_byte(output, offset, length, limits)
  })
  decode_raw_loop(rest, new_output, limits)
}

fn copy_byte_by_byte(
  output: BitArray,
  offset: Int,
  length: Int,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  case length {
    0 -> Ok(output)
    _ -> {
      let size = bit_array.byte_size(output)
      let assert Ok(byte_slice) = bit_array.slice(output, size - offset, 1)
      use new_output <- result.try(append_with_limit(output, byte_slice, limits))
      copy_byte_by_byte(new_output, offset, length - 1, limits)
    }
  }
}

fn emit_literal(bytes: BitArray) -> BitArray {
  let length = bit_array.byte_size(bytes)
  case length {
    0 -> <<>>
    _ -> {
      let encoded_len = length - 1
      let header = case encoded_len < 60 {
        True -> <<int.bitwise_shift_left(encoded_len, 2)>>
        False -> {
          let #(extra, width) = literal_extension(encoded_len)
          bit_array.concat([
            <<int.bitwise_shift_left(60 + width - 1, 2)>>,
            extra,
          ])
        }
      }
      bit_array.concat([header, bytes])
    }
  }
}

fn literal_extension(encoded_len: Int) -> #(BitArray, Int) {
  case encoded_len < 0x100 {
    True -> #(<<encoded_len>>, 1)
    False ->
      case encoded_len < 0x10000 {
        True -> #(<<encoded_len:size(16)-little>>, 2)
        False ->
          case encoded_len < 0x1000000 {
            True -> #(<<encoded_len:size(24)-little>>, 3)
            False -> #(<<encoded_len:size(32)-little>>, 4)
          }
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
