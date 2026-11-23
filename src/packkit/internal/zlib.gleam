//// RFC 1950 zlib codec.
////
//// zlib wraps a DEFLATE stream in a two-byte header and a trailing
//// Adler-32 checksum.  The decoder checks the CMF/FLG check bits and the
//// Adler-32, and rejects streams that need a preset dictionary.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/result
import packkit/codec
import packkit/internal/checksum
import packkit/internal/deflate
import packkit/limit

const cmf_byte: Int = 0x78

const flg_byte: Int = 0x01

const fdict_flag: Int = 0x20

/// Encode `data` as a zlib byte stream.  The DEFLATE body uses the
/// dynamic-Huffman encoder (BTYPE=10) for better compression on
/// typical inputs; pathologically-skewed payloads fall back to
/// fixed Huffman (BTYPE=01) inside `deflate.encode_dynamic`.
pub fn encode(bytes bytes: BitArray) -> Result(BitArray, codec.CodecError) {
  let deflated = deflate.encode_dynamic(bytes: bytes)
  let header = <<cmf_byte, flg_byte>>
  let trailer = adler_trailer(bytes)
  Ok(bit_array.concat([header, deflated, trailer]))
}

/// Decode a zlib byte stream.  Returns `DictionaryRequired` when the
/// stream sets the `FDICT` bit.
pub fn decode_with_limits(
  bytes bytes: BitArray,
  limits limits: limit.Limits,
) -> Result(BitArray, codec.CodecError) {
  use <- bool.guard(
    when: bit_array.byte_size(bytes) > limits.max_input_bytes,
    return: Error(codec.LimitExceeded(
      limit: "max_input_bytes",
      actual: bit_array.byte_size(bytes),
    )),
  )

  case bytes {
    <<cmf, flg, rest:bytes>> -> {
      use <- bool.guard(
        when: int.bitwise_and(cmf, 0x0F) != 8,
        return: Error(codec.InvalidData(
          message: "zlib: compression method is not deflate",
        )),
      )

      use <- bool.guard(
        when: { cmf * 256 + flg } % 31 != 0,
        return: Error(codec.InvalidData(
          message: "zlib: header check bits mismatch",
        )),
      )

      // CINFO is the base-2 logarithm of the window size minus 8, and
      // RFC 1950 §2.2 does not allow windows over 32 KiB (CINFO > 7).
      use <- bool.guard(
        when: int.bitwise_shift_right(cmf, 4) > 7,
        return: Error(codec.InvalidData(
          message: "zlib: window size is larger than 32 KiB",
        )),
      )
      use <- bool.guard(
        when: int.bitwise_and(flg, fdict_flag) != 0,
        return: Error(codec.DictionaryRequired),
      )

      let payload_size = bit_array.byte_size(rest)
      use <- bool.guard(
        when: payload_size < 4,
        return: Error(codec.InvalidData(
          message: "zlib: stream missing Adler-32 trailer",
        )),
      )

      let deflate_size = payload_size - 4
      let assert Ok(deflate_bits) = bit_array.slice(rest, 0, deflate_size)
      let assert Ok(checksum_bits) = bit_array.slice(rest, deflate_size, 4)

      use plain <- result.try(deflate.decode_with_limits(
        bytes: deflate_bits,
        limits: limits,
      ))

      let expected = checksum.adler32(plain)
      let assert <<stored:size(32)-big>> = checksum_bits
      use <- bool.guard(
        when: stored != expected,
        return: Error(codec.InvalidData(message: "zlib: Adler-32 mismatch")),
      )

      Ok(plain)
    }
    _ -> Error(codec.InvalidData(message: "zlib: input too short for header"))
  }
}

fn adler_trailer(payload: BitArray) -> BitArray {
  let value = checksum.adler32(payload)
  <<value:size(32)-big>>
}
