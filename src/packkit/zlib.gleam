//// RFC 1950 zlib codec.
////
//// zlib wraps a DEFLATE stream in a two-byte header and a trailing
//// Adler-32 checksum.  The encoder delegates to the DEFLATE
//// fixed-Huffman writer; the decoder enforces the CMF/FLG check bits
//// and the trailing Adler-32, and can resolve the optional `FDICT`
//// preset-dictionary path when the caller supplies the dictionary.

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

const flg_byte_with_dict: Int = 0xBB

const fdict_flag: Int = 0x20

/// Zlib codec smart constructor.
pub fn codec() -> codecs.Codec {
  codecs.zlib()
}

/// Encode `data` as a zlib byte stream.  The DEFLATE body uses the
/// dynamic-Huffman encoder (BTYPE=10) for better compression on
/// typical inputs; pathologically-skewed payloads fall back to
/// fixed Huffman (BTYPE=01) inside `deflate.encode_dynamic`.
pub fn encode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  use deflated <- result.try(deflate.encode_dynamic(bytes: bytes))
  let header = <<cmf_byte, flg_byte>>
  let trailer = adler_trailer(bytes)
  Ok(bit_array.concat([header, deflated, trailer]))
}

/// Encode `bytes` as a zlib stream carrying the preset-dictionary
/// adler ID for `dictionary`.  The body is emitted by the
/// dynamic-Huffman DEFLATE encoder over `bytes` alone; the receiver
/// must already share `dictionary` to verify the four-byte DICT_ID.
/// Callers that have the dictionary on both sides can use this to
/// round-trip a stream they will later decode with
/// `decode_with_dictionary`.
pub fn encode_with_dictionary(
  bytes bytes: BitArray,
  dictionary dictionary: BitArray,
) -> Result(BitArray, error.CodecError) {
  use deflated <- result.try(deflate.encode_dynamic(bytes: bytes))
  let dict_id = checksum.adler32(dictionary)
  let header = <<cmf_byte, flg_byte_with_dict, dict_id:size(32)-big>>
  let trailer = adler_trailer(bytes)
  Ok(bit_array.concat([header, deflated, trailer]))
}

/// Decode a zlib byte stream using default limits.
pub fn decode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  decode_with_limits(bytes: bytes, limits: limit.default())
}

/// Decode a zlib byte stream using explicit limits.  Returns
/// `CodecDictionaryRequired` when the stream sets the `FDICT` bit;
/// use [decode_with_dictionary] in that case.
pub fn decode_with_limits(
  bytes bytes: BitArray,
  limits limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  decode_inner(bytes: bytes, limits: limits, dictionary: <<>>, has_dict: False)
}

/// Decode a zlib byte stream that uses the FDICT preset-dictionary
/// path.  Verifies the four-byte DICT_ID against the supplied bytes
/// and returns `CodecDictionaryMismatch` when they do not agree.  If
/// `bytes` does not advertise FDICT this falls through to the regular
/// decoder so callers can pass the dictionary defensively.
pub fn decode_with_dictionary(
  bytes bytes: BitArray,
  dictionary dictionary: BitArray,
) -> Result(BitArray, error.CodecError) {
  decode_with_dictionary_and_limits(
    bytes: bytes,
    dictionary: dictionary,
    limits: limit.default(),
  )
}

/// Like [decode_with_dictionary] but accepts an explicit `Limits`
/// value.
pub fn decode_with_dictionary_and_limits(
  bytes bytes: BitArray,
  dictionary dictionary: BitArray,
  limits limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  decode_inner(
    bytes: bytes,
    limits: limits,
    dictionary: dictionary,
    has_dict: True,
  )
}

fn decode_inner(
  bytes bytes: BitArray,
  limits limits: limit.Limits,
  dictionary dictionary: BitArray,
  has_dict has_dict: Bool,
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

      // CINFO carries window-size bits = CINFO + 8 (RFC 1950 §2.2).
      // Reject window sizes that exceed the caller's `max_window_bits`.
      let cinfo = int.bitwise_shift_right(cmf, 4)
      let window_bits = cinfo + 8
      use <- bool.guard(
        when: window_bits > limit.max_window_bits(limits),
        return: Error(error.CodecLimitExceeded(
          limit: "max_window_bits",
          actual: window_bits,
        )),
      )

      let has_fdict_bit = int.bitwise_and(flg, fdict_flag) != 0
      use rest <- result.try(consume_fdict_if_present(
        rest,
        has_fdict_bit,
        has_dict,
        dictionary,
      ))

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

fn consume_fdict_if_present(
  rest: BitArray,
  has_fdict_bit: Bool,
  has_dict: Bool,
  dictionary: BitArray,
) -> Result(BitArray, error.CodecError) {
  case has_fdict_bit, has_dict {
    False, _ -> Ok(rest)
    True, False -> Error(error.CodecDictionaryRequired(name: "zlib"))
    True, True -> verify_dict_id(rest, dictionary)
  }
}

fn verify_dict_id(
  rest: BitArray,
  dictionary: BitArray,
) -> Result(BitArray, error.CodecError) {
  case rest {
    <<stored_dict_id:size(32)-big, after_dict_id:bytes>> -> {
      let expected = checksum.adler32(dictionary)
      case stored_dict_id == expected {
        True -> Ok(after_dict_id)
        False -> Error(error.CodecDictionaryMismatch(name: "zlib"))
      }
    }
    _ ->
      Error(error.CodecInvalidData(
        message: "zlib: FDICT set but DICT_ID truncated",
      ))
  }
}
