//// RFC 1950 zlib codec.
////
//// zlib wraps a DEFLATE stream in a two-byte header and a trailing
//// Adler-32 checksum.  The encoder here delegates to the DEFLATE
//// stored-block writer; once a Huffman-based DEFLATE encoder lands
//// this module gains real compression "for free".

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/result
import packkit/checksum
import packkit/codec as codecs
import packkit/deflate
import packkit/error
import packkit/limit

const cmf_byte: Int = 0x78

const flg_byte: Int = 0x01

const fdict_flag: Int = 0x20

/// Zlib codec smart constructor.
pub fn codec() -> codecs.Codec {
  codecs.zlib()
}

/// Encode `data` as a zlib byte stream.
pub fn encode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  use deflated <- result.try(deflate.encode(bytes: bytes))
  let header = <<cmf_byte, flg_byte>>
  let trailer = adler_trailer(bytes)
  Ok(bit_array.concat([header, deflated, trailer]))
}

/// Decode a zlib byte stream using default limits.
pub fn decode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  decode_with_limits(bytes: bytes, limits: limit.default())
}

/// Decode a zlib byte stream using explicit limits.
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
    <<cmf, flg, rest:bytes>> -> {
      use <- bool.guard(
        when: int.bitwise_and(cmf, 0x0F) != 8,
        return: Error(error.CodecInvalidData(
          message: "zlib: compression method is not deflate",
        )),
      )

      use <- bool.guard(
        when: { cmf * 256 + flg } % 31 != 0,
        return: Error(error.CodecInvalidData(
          message: "zlib: header check bits mismatch",
        )),
      )

      use <- bool.guard(
        when: int.bitwise_and(flg, fdict_flag) != 0,
        return: Error(error.CodecDictionaryRequired(name: "zlib")),
      )

      let payload_size = bit_array.byte_size(rest)
      use <- bool.guard(
        when: payload_size < 4,
        return: Error(error.CodecInvalidData(
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
        return: Error(error.CodecInvalidData(message: "zlib: Adler-32 mismatch")),
      )

      Ok(plain)
    }
    _ ->
      Error(error.CodecInvalidData(message: "zlib: input too short for header"))
  }
}

fn adler_trailer(payload: BitArray) -> BitArray {
  let value = checksum.adler32(payload)
  <<value:size(32)-big>>
}
