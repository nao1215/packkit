//// Zstandard codec scaffolding.
////
//// Zstandard frames combine literal-section Huffman streams, FSE
//// sequence streams, and an optional dictionary.  The decoder is
//// intentionally deferred so the encoder and decoder can grow on the
//// same well-typed API.  This module pins the public shape and emits
//// typed `*NotImplemented` errors until the implementation lands.

import packkit/codec as codecs
import packkit/error

/// Zstandard codec smart constructor.
pub fn codec() -> codecs.Codec {
  codecs.zstd()
}

/// Encode `bytes` as a Zstandard frame.  Not yet implemented.
pub fn encode(bytes _bytes: BitArray) -> Result(BitArray, error.CodecError) {
  Error(error.CodecNotImplemented(feature: "zstd.encode"))
}

/// Decode a Zstandard frame.  Not yet implemented.
pub fn decode(bytes _bytes: BitArray) -> Result(BitArray, error.CodecError) {
  Error(error.CodecNotImplemented(feature: "zstd.decode"))
}
