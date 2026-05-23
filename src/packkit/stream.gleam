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
///
/// `buffered_bytes` is tracked so `push` can enforce `max_input_bytes`
/// incrementally — a hostile or buggy producer can no longer stream
/// arbitrarily many chunks into the decoder before the budget check
/// fires at `finish` time.
pub opaque type Decoder {
  Decoder(
    kind: DecoderKind,
    buffer: List(BitArray),
    buffered_bytes: Int,
    limits: limit.Limits,
  )
}

type DecoderKind {
  Deflate
  Zlib
  Gzip
}

/// Start a new incremental DEFLATE decoder using the default limits.
pub fn new_deflate_decoder() -> Decoder {
  new_decoder(Deflate, limit.default())
}

/// Start a new incremental zlib decoder using the default limits.
pub fn new_zlib_decoder() -> Decoder {
  new_decoder(Zlib, limit.default())
}

/// Start a new incremental gzip decoder using the default limits.
pub fn new_gzip_decoder() -> Decoder {
  new_decoder(Gzip, limit.default())
}

fn new_decoder(kind: DecoderKind, limits: limit.Limits) -> Decoder {
  Decoder(kind: kind, buffer: [], buffered_bytes: 0, limits: limits)
}

/// Replace the limits used by an incremental decoder.
pub fn with_limits(decoder: Decoder, limits limits: limit.Limits) -> Decoder {
  Decoder(..decoder, limits: limits)
}

/// Append a chunk of input bytes to the decoder, enforcing
/// `max_input_bytes` incrementally.  Returns a typed
/// `CodecLimitExceeded` if the running buffered byte count would
/// exceed the configured limit.
pub fn push(
  decoder: Decoder,
  chunk: BitArray,
) -> Result(Decoder, error.CodecError) {
  let chunk_size = bit_array.byte_size(chunk)
  let new_total = decoder.buffered_bytes + chunk_size
  case new_total > limit.max_input_bytes(decoder.limits) {
    True ->
      Error(error.CodecLimitExceeded(
        limit: "max_input_bytes",
        actual: new_total,
      ))
    False ->
      Ok(
        Decoder(
          ..decoder,
          buffer: [chunk, ..decoder.buffer],
          buffered_bytes: new_total,
        ),
      )
  }
}

/// Finalize the decoder and return the full decoded payload.
pub fn finish(decoder: Decoder) -> Result(BitArray, error.CodecError) {
  // Single `bit_array.concat` over the forward-order list is
  // O(total_bytes); a per-chunk fold that prepended into an
  // accumulator would copy the growing accumulator each iteration.
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
/// order and returns the final decoded payload.  Surfaces the same
/// typed `CodecLimitExceeded` `push` would, so a long sequence of
/// chunks cannot silently overrun the input budget.
pub fn decode_chunks(
  decoder decoder: Decoder,
  chunks chunks: List(BitArray),
) -> Result(BitArray, error.CodecError) {
  use fed <- result.try(feed_all(decoder, chunks))
  finish(fed)
}

fn feed_all(
  decoder: Decoder,
  chunks: List(BitArray),
) -> Result(Decoder, error.CodecError) {
  case chunks {
    [] -> Ok(decoder)
    [head, ..rest] -> {
      use next <- result.try(push(decoder, head))
      feed_all(next, rest)
    }
  }
}
