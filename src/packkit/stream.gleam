//// Streaming helpers for codec families.
////
//// `packkit/stream` exposes opaque decoder states that buffer input
//// chunks and run a one-shot decode at `finish` time.  The API matches
//// the streaming shape the spec calls for - `new_*_decoder`, `push`,
//// `finish` - so callers can already wire incremental pipelines even
//// while the underlying codec decoders are still eager.

import gleam/bit_array
import gleam/list
import gleam/result
import packkit/deflate
import packkit/error
import packkit/gzip
import packkit/limit
import packkit/zlib

/// Opaque incremental decoder state.  The wrapped codec selector is
/// kept private; callers should construct one of the `new_*_decoder`
/// values and feed it through `push`/`finish`.
pub opaque type Decoder {
  Decoder(kind: DecoderKind, buffer: List(BitArray), limits: limit.Limits)
}

type DecoderKind {
  Deflate
  Zlib
  Gzip
}

/// Start a new incremental DEFLATE decoder using the default limits.
pub fn new_deflate_decoder() -> Decoder {
  Decoder(kind: Deflate, buffer: [], limits: limit.default())
}

/// Start a new incremental zlib decoder using the default limits.
pub fn new_zlib_decoder() -> Decoder {
  Decoder(kind: Zlib, buffer: [], limits: limit.default())
}

/// Start a new incremental gzip decoder using the default limits.
pub fn new_gzip_decoder() -> Decoder {
  Decoder(kind: Gzip, buffer: [], limits: limit.default())
}

/// Replace the limits used by an incremental decoder.
pub fn with_limits(decoder: Decoder, limits limits: limit.Limits) -> Decoder {
  Decoder(..decoder, limits: limits)
}

/// Append a chunk of input bytes to the decoder.
pub fn push(decoder: Decoder, chunk: BitArray) -> Decoder {
  Decoder(..decoder, buffer: [chunk, ..decoder.buffer])
}

/// Finalize the decoder and return the full decoded payload.
pub fn finish(decoder: Decoder) -> Result(BitArray, error.CodecError) {
  let bytes = bit_array.concat(list.reverse(decoder.buffer))
  case decoder.kind {
    Deflate -> deflate.decode_with_limits(bytes: bytes, limits: decoder.limits)
    Zlib -> zlib.decode_with_limits(bytes: bytes, limits: decoder.limits)
    Gzip ->
      gzip.decode_with_limits(bytes: bytes, limits: decoder.limits)
      |> result.map(fn(decoded) { decoded.payload })
  }
}

/// Convenience helper that pushes every chunk through the decoder in
/// order and returns the final decoded payload.
pub fn decode_chunks(
  decoder decoder: Decoder,
  chunks chunks: List(BitArray),
) -> Result(BitArray, error.CodecError) {
  let fed = list.fold(chunks, decoder, fn(d, chunk) { push(d, chunk) })
  finish(fed)
}
