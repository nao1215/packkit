//// Brotli codec scaffolding.
////
//// Brotli combines metablock encoding, context modeling, and a static
//// dictionary.  Building a correct pure-Gleam decoder is large enough
//// that the implementation is deferred; this module pins the public
//// API so the rest of the codec namespace can refer to it.

import packkit/codec as codecs
import packkit/error

/// Brotli codec smart constructor.
pub fn codec() -> codecs.Codec {
  codecs.brotli()
}

/// Encode `bytes` as a Brotli stream.  Not yet implemented.
pub fn encode(bytes _bytes: BitArray) -> Result(BitArray, error.CodecError) {
  Error(error.CodecNotImplemented(feature: "brotli.encode"))
}

/// Decode a Brotli stream.  Not yet implemented.
pub fn decode(bytes _bytes: BitArray) -> Result(BitArray, error.CodecError) {
  Error(error.CodecNotImplemented(feature: "brotli.decode"))
}
