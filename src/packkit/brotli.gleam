//// Brotli codec — partial pure-Gleam decoder.
////
//// The decoder currently recognises the canonical empty brotli
//// stream (`0x3F`) emitted by `brotli -c < /dev/null`.  Non-empty
//// streams require the full RFC 7932 machinery — variable-length
//// WBITS, metablock framing, context modelling, two prefix-code
//// alphabets, and the ~120 KiB built-in static dictionary — which
//// is intentionally deferred.  Non-empty inputs return
//// `CodecNotImplemented` so future work can plug in the entropy and
//// dictionary layers without changing the public surface.

import gleam/bit_array
import gleam/bool
import packkit/codec as codecs
import packkit/error
import packkit/limit

/// Brotli codec smart constructor.
pub fn codec() -> codecs.Codec {
  codecs.brotli()
}

/// Encode `bytes` as a Brotli stream.  Not yet implemented.
pub fn encode(bytes _bytes: BitArray) -> Result(BitArray, error.CodecError) {
  Error(error.CodecNotImplemented(feature: "brotli.encode"))
}

/// Decode a Brotli stream using default limits.
pub fn decode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  decode_with_limits(bytes: bytes, limits: limit.default())
}

/// Decode a Brotli stream using explicit limits.
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
    <<0x3F>> -> Ok(<<>>)
    <<>> -> Error(error.CodecInvalidData(message: "empty brotli stream"))
    _ ->
      Error(error.CodecNotImplemented(
        feature: "brotli non-empty streams (RFC 7932 metablocks + static dictionary)",
      ))
  }
}
