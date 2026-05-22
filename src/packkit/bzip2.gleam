//// bzip2 codec scaffolding.
////
//// bzip2 streams (`BZh` magic) chain Run-Length Encoding 1, the
//// Burrows-Wheeler transform, Move-To-Front, an RLE-2 step, and
//// grouped Huffman coding.  The full decoder is intentionally
//// deferred; this module exposes the public API surface and emits
//// typed `*NotImplemented` errors so callers can plan around it.

import packkit/codec as codecs
import packkit/error

/// bzip2 codec smart constructor.
pub fn codec() -> codecs.Codec {
  codecs.bzip2()
}

/// Encode `bytes` as a bzip2 stream.  Not yet implemented.
pub fn encode(bytes _bytes: BitArray) -> Result(BitArray, error.CodecError) {
  Error(error.CodecNotImplemented(feature: "bzip2.encode"))
}

/// Decode a bzip2 stream.  Not yet implemented.
pub fn decode(bytes _bytes: BitArray) -> Result(BitArray, error.CodecError) {
  Error(error.CodecNotImplemented(feature: "bzip2.decode"))
}
