//// xz codec scaffolding.
////
//// xz streams pack one or more LZMA2 filter chains inside a framed
//// container that ends with an index and stream-footer block.  The
//// decoder is intentionally deferred while the LZMA range coder and
//// filter pipeline are being worked out; this module pins the public
//// API so the rest of the codec namespace can refer to it.

import packkit/codec as codecs
import packkit/error

/// xz codec smart constructor.
pub fn codec() -> codecs.Codec {
  codecs.xz()
}

/// Encode `bytes` as an xz stream.  Not yet implemented.
pub fn encode(bytes _bytes: BitArray) -> Result(BitArray, error.CodecError) {
  Error(error.CodecNotImplemented(feature: "xz.encode"))
}

/// Decode an xz stream.  Not yet implemented.
pub fn decode(bytes _bytes: BitArray) -> Result(BitArray, error.CodecError) {
  Error(error.CodecNotImplemented(feature: "xz.decode"))
}
