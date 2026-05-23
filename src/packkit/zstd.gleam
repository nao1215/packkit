//// Zstandard codec — partial pure-Gleam decoder.
////
//// The module parses the Zstandard frame envelope: the 4-byte magic,
//// the variable-length frame header (descriptor + window descriptor
//// + optional dictionary id + optional frame content size), and the
//// trailing optional 4-byte content checksum.  Raw and RLE blocks
//// are decoded end-to-end; the FSE/Huffman compressed block layer
//// is intentionally deferred and returns
//// `CodecNotImplemented(feature: "zstd compressed blocks (FSE + Huffman)")`
//// so future work can swap in the entropy decoder without changing
//// the public surface or the frame parser.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/result
import packkit/codec as codecs
import packkit/error
import packkit/limit

const magic: Int = 0xFD2FB528

/// Zstandard codec smart constructor.
pub fn codec() -> codecs.Codec {
  codecs.zstd()
}

/// Encode `bytes` as a Zstandard frame.  Not yet implemented.
pub fn encode(bytes _bytes: BitArray) -> Result(BitArray, error.CodecError) {
  Error(error.CodecNotImplemented(feature: "zstd.encode"))
}

/// Decode a Zstandard frame using default limits.
pub fn decode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  decode_with_limits(bytes: bytes, limits: limit.default())
}

/// Decode a Zstandard frame using explicit limits.
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

  use #(checksum_flag, rest) <- result.try(parse_frame_header(bytes))
  use #(output, rest) <- result.try(decode_blocks(rest, <<>>, limits))
  use _ <- result.try(consume_checksum(rest, checksum_flag))
  Ok(output)
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

fn decode_blocks(
  bytes: BitArray,
  output: BitArray,
  limits: limit.Limits,
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
      use #(plain, rest) <- result.try(decode_one_block(
        rest,
        block_type,
        block_size,
      ))
      use new_output <- result.try(append_with_limit(output, plain, limits))
      case last {
        True -> Ok(#(new_output, rest))
        False -> decode_blocks(rest, new_output, limits)
      }
    }
    _ -> Error(error.CodecInvalidData(message: "truncated zstd block header"))
  }
}

fn decode_one_block(
  bytes: BitArray,
  block_type: Int,
  block_size: Int,
) -> Result(#(BitArray, BitArray), error.CodecError) {
  case block_type {
    0 -> decode_raw_block(bytes, block_size)
    1 -> decode_rle_block(bytes, block_size)
    2 ->
      Error(error.CodecNotImplemented(
        feature: "zstd compressed blocks (FSE + Huffman)",
      ))
    _ -> Error(error.CodecInvalidData(message: "zstd reserved block type 3"))
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

// -- trailing content checksum -----------------------------------------

fn consume_checksum(
  bytes: BitArray,
  checksum_flag: Bool,
) -> Result(Nil, error.CodecError) {
  case checksum_flag {
    False -> Ok(Nil)
    True ->
      case bit_array.byte_size(bytes) {
        4 -> Ok(Nil)
        // The 4-byte checksum is consumed but not verified — xxHash64
        // is not yet implemented in pure Gleam.  Future work can read
        // the value and confirm it against an xxh64 of the decoded
        // bytes.
        n if n < 4 ->
          Error(error.CodecInvalidData(
            message: "zstd content checksum is shorter than 4 bytes",
          ))
        _ ->
          Error(error.CodecInvalidData(
            message: "zstd frame has trailing bytes after checksum",
          ))
      }
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
        value: projected,
      ))
    False -> Ok(bit_array.concat([output, chunk]))
  }
}
