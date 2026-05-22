//// LZ4 frame format codec.
////
//// This module decodes LZ4 frames (magic `0x184D2204`) as specified
//// in the LZ4 Frame Format Description and emits frames that store
//// every block in the uncompressed form.  Round-trip correctness is
//// guaranteed for any conforming decoder; the encoder simply leaves
//// real LZ4 block compression as future work.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/result
import packkit/codec as codecs
import packkit/error
import packkit/limit

const magic: Int = 0x184D2204

const flg_version_mask: Int = 0xC0

const flg_version_v1: Int = 0x40

const flg_block_checksum: Int = 0x10

const flg_content_size: Int = 0x08

const flg_content_checksum: Int = 0x04

const flg_dict_id: Int = 0x01

const uncompressed_block_bit: Int = 0x80000000

const u32_mask: Int = 0xFFFFFFFF

const default_block_max: Int = 4_194_304

/// LZ4 frame codec smart constructor.
pub fn codec() -> codecs.Codec {
  codecs.lz4_frame()
}

/// Encode `bytes` as an LZ4 frame using uncompressed blocks.
pub fn encode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  let header = <<magic:size(32)-little, 0x60, 0x70, 0x73>>
  let blocks = encode_blocks(bytes, [])
  let end_mark = <<0:size(32)-little>>
  Ok(bit_array.concat([header, blocks, end_mark]))
}

/// Decode an LZ4 frame using the default resource limits.
pub fn decode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  decode_with_limits(bytes: bytes, limits: limit.default())
}

/// Decode an LZ4 frame using explicit resource limits.
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

  case bytes {
    <<m:size(32)-little, flg, bd, rest:bytes>> -> {
      use <- bool.guard(
        when: m != magic,
        return: Error(error.CodecInvalidData(message: "lz4: bad frame magic")),
      )

      use <- bool.guard(
        when: int.bitwise_and(flg, flg_version_mask) != flg_version_v1,
        return: Error(error.CodecInvalidData(
          message: "lz4: unsupported frame version",
        )),
      )

      let block_checksum = int.bitwise_and(flg, flg_block_checksum) != 0
      let content_size_present = int.bitwise_and(flg, flg_content_size) != 0
      let content_checksum = int.bitwise_and(flg, flg_content_checksum) != 0
      let dict_id_present = int.bitwise_and(flg, flg_dict_id) != 0

      let bd_block_max_idx = int.bitwise_and(int.bitwise_shift_right(bd, 4), 7)
      let block_max = block_max_bytes(bd_block_max_idx)

      use rest <- result.try(maybe_skip(
        rest,
        content_size_present,
        8,
        "lz4: content size truncated",
      ))
      use rest <- result.try(maybe_skip(
        rest,
        dict_id_present,
        4,
        "lz4: dictionary id truncated",
      ))
      use rest <- result.try(maybe_skip(
        rest,
        True,
        1,
        "lz4: header checksum missing",
      ))

      decode_blocks(
        rest,
        <<>>,
        block_checksum,
        content_checksum,
        block_max,
        limits,
      )
    }
    _ -> Error(error.CodecInvalidData(message: "lz4: frame header truncated"))
  }
}

fn encode_blocks(remaining: BitArray, acc: List(BitArray)) -> BitArray {
  let total = bit_array.byte_size(remaining)
  case total {
    0 -> bit_array.concat(list.reverse(acc))
    _ -> {
      let chunk_size = case total > default_block_max {
        True -> default_block_max
        False -> total
      }
      let assert Ok(chunk) = bit_array.slice(remaining, 0, chunk_size)
      let assert Ok(after) =
        bit_array.slice(remaining, chunk_size, total - chunk_size)
      let header_bits = <<
        int.bitwise_or(uncompressed_block_bit, chunk_size):size(32)-little,
      >>
      encode_blocks(after, [bit_array.concat([header_bits, chunk]), ..acc])
    }
  }
}

fn decode_blocks(
  bytes: BitArray,
  output: BitArray,
  block_checksum: Bool,
  content_checksum: Bool,
  block_max: Int,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  case bytes {
    <<0:size(32)-little, rest:bytes>> ->
      finalize(rest, output, content_checksum)
    <<header:size(32)-little, rest:bytes>> -> {
      let uncompressed = int.bitwise_and(header, uncompressed_block_bit) != 0
      let block_size =
        int.bitwise_and(
          header,
          int.bitwise_exclusive_or(u32_mask, uncompressed_block_bit),
        )
      use <- bool.guard(
        when: block_size > block_max,
        return: Error(error.CodecInvalidData(
          message: "lz4: block size exceeds frame max block size",
        )),
      )

      case bit_array.byte_size(rest) < block_size {
        True ->
          Error(error.CodecInvalidData(message: "lz4: block payload truncated"))
        False -> {
          let assert Ok(block) = bit_array.slice(rest, 0, block_size)
          let assert Ok(after_block) =
            bit_array.slice(
              rest,
              block_size,
              bit_array.byte_size(rest) - block_size,
            )

          use after_block <- result.try(case block_checksum {
            True ->
              case bit_array.byte_size(after_block) < 4 {
                True ->
                  Error(error.CodecInvalidData(
                    message: "lz4: block checksum missing",
                  ))
                False -> {
                  let assert Ok(after) =
                    bit_array.slice(
                      after_block,
                      4,
                      bit_array.byte_size(after_block) - 4,
                    )
                  Ok(after)
                }
              }
            False -> Ok(after_block)
          })

          use new_output <- result.try(case uncompressed {
            True -> append_with_limit(output, block, limits)
            False -> decode_block(block, output, limits)
          })

          decode_blocks(
            after_block,
            new_output,
            block_checksum,
            content_checksum,
            block_max,
            limits,
          )
        }
      }
    }
    _ -> Error(error.CodecInvalidData(message: "lz4: block header truncated"))
  }
}

fn finalize(
  after_end: BitArray,
  output: BitArray,
  content_checksum: Bool,
) -> Result(BitArray, error.CodecError) {
  case content_checksum {
    False -> Ok(output)
    True ->
      case bit_array.byte_size(after_end) >= 4 {
        True -> Ok(output)
        False ->
          Error(error.CodecInvalidData(message: "lz4: content checksum missing"))
      }
  }
}

fn decode_block(
  block: BitArray,
  output: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  case bit_array.byte_size(block) {
    0 -> Ok(output)
    _ -> decode_block_loop(block, output, limits)
  }
}

fn decode_block_loop(
  block: BitArray,
  output: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  case block {
    <<token, rest:bytes>> -> {
      let lit_len_base = int.bitwise_shift_right(token, 4)
      let match_len_base = int.bitwise_and(token, 0x0F)

      use #(lit_len, rest) <- result.try(case lit_len_base {
        15 -> read_extension(rest, 15)
        _ -> Ok(#(lit_len_base, rest))
      })

      case bit_array.byte_size(rest) < lit_len {
        True ->
          Error(error.CodecInvalidData(
            message: "lz4: literal length exceeds block payload",
          ))
        False -> {
          let assert Ok(literals) = bit_array.slice(rest, 0, lit_len)
          let assert Ok(after_literals) =
            bit_array.slice(rest, lit_len, bit_array.byte_size(rest) - lit_len)

          use output <- result.try(append_with_limit(output, literals, limits))

          case bit_array.byte_size(after_literals) {
            0 -> Ok(output)
            _ ->
              case after_literals {
                <<offset:size(16)-little, after_offset:bytes>> -> {
                  use <- bool.guard(
                    when: offset == 0,
                    return: Error(error.CodecInvalidData(
                      message: "lz4: zero match offset",
                    )),
                  )

                  use #(match_len_extra, after_offset) <- result.try(
                    case match_len_base {
                      15 -> read_extension(after_offset, 15)
                      _ -> Ok(#(match_len_base, after_offset))
                    },
                  )

                  let match_len = match_len_extra + 4

                  use <- bool.guard(
                    when: offset > bit_array.byte_size(output),
                    return: Error(error.CodecInvalidData(
                      message: "lz4: match offset exceeds output",
                    )),
                  )

                  use output <- result.try(copy_match(
                    output,
                    offset,
                    match_len,
                    limits,
                  ))

                  decode_block_loop(after_offset, output, limits)
                }
                _ ->
                  Error(error.CodecInvalidData(
                    message: "lz4: match offset truncated",
                  ))
              }
          }
        }
      }
    }
    <<>> -> Ok(output)
    _ -> Error(error.CodecInvalidData(message: "lz4: malformed block"))
  }
}

fn read_extension(
  bytes: BitArray,
  acc: Int,
) -> Result(#(Int, BitArray), error.CodecError) {
  case bytes {
    <<b, rest:bytes>> ->
      case b {
        0xFF -> read_extension(rest, acc + 0xFF)
        _ -> Ok(#(acc + b, rest))
      }
    _ ->
      Error(error.CodecInvalidData(message: "lz4: length extension truncated"))
  }
}

fn copy_match(
  output: BitArray,
  offset: Int,
  length: Int,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  case length {
    0 -> Ok(output)
    _ -> {
      let size = bit_array.byte_size(output)
      case offset >= length {
        True -> {
          let assert Ok(chunk) = bit_array.slice(output, size - offset, length)
          append_with_limit(output, chunk, limits)
        }
        False -> copy_match_byte_by_byte(output, offset, length, limits)
      }
    }
  }
}

fn copy_match_byte_by_byte(
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
      copy_match_byte_by_byte(new_output, offset, length - 1, limits)
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

fn maybe_skip(
  bytes: BitArray,
  active: Bool,
  count: Int,
  message: String,
) -> Result(BitArray, error.CodecError) {
  case active {
    False -> Ok(bytes)
    True ->
      case bit_array.byte_size(bytes) < count {
        True -> Error(error.CodecInvalidData(message: message))
        False -> {
          let assert Ok(after) =
            bit_array.slice(bytes, count, bit_array.byte_size(bytes) - count)
          Ok(after)
        }
      }
  }
}

fn block_max_bytes(index: Int) -> Int {
  case index {
    4 -> 64_000
    5 -> 256_000
    6 -> 1_000_000
    7 -> 4_000_000
    _ -> 4_000_000
  }
}
