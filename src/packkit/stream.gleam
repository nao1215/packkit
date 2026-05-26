//// Streaming helpers for codec families.
////
//// `packkit/stream` exposes opaque decoder states that buffer input
//// chunks and run a one-shot decode at `finish` time.  The API matches
//// the streaming shape the spec calls for - `new_*_decoder`, `push`,
//// `finish` - so callers can already wire incremental pipelines even
//// while the underlying codec decoders are still eager.
////
//// **Relationship to `packkit/codec.Codec`.**  The streaming
//// constructors (`new_gzip_encoder`, `new_zstd_decoder`, ...) do NOT
//// accept a `packkit/codec.Codec` value, so the per-codec `Level` /
//// preset `Dictionary` settings carried by a `Codec` are not threaded
//// through this API; every stream uses the codec's default encode
//// strategy.  This is intentional: a `Codec` is the config object
//// `packkit.compress` / `packkit.decompress` (the one-shot facade)
//// consumes, while `packkit/stream` only ever invokes the codec
//// module's bare `encode/1` / `decode/1` entry points.  Callers that
//// need a non-default level or a preset dictionary should call the
//// per-codec module directly (`gzip.encode_with_header`,
//// `zlib.encode_with_dictionary`, `deflate.encode_dynamic`, …) and
//// drive the chunking themselves until the streaming API grows
//// codec-typed constructors.  The `Limits` value, by contrast, IS
//// honoured incrementally — see [push] / [push_encoder].

import gleam/bit_array
import gleam/list
import gleam/result
import packkit/brotli
import packkit/bzip2
import packkit/deflate
import packkit/error
import packkit/gzip
import packkit/limit
import packkit/lz4
import packkit/lzw
import packkit/snappy
import packkit/xz
import packkit/zlib
import packkit/zstd

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
  Lz4
  Snappy
  Bzip2
  Lzw
  Xz
  Zstd
  Brotli
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

/// Start a new incremental LZ4 frame decoder using the default limits.
pub fn new_lz4_decoder() -> Decoder {
  new_decoder(Lz4, limit.default())
}

/// Start a new incremental Snappy (framed) decoder using the default
/// limits.  See [packkit/snappy] for the raw-block variants.
pub fn new_snappy_decoder() -> Decoder {
  new_decoder(Snappy, limit.default())
}

/// Start a new incremental bzip2 decoder using the default limits.
pub fn new_bzip2_decoder() -> Decoder {
  new_decoder(Bzip2, limit.default())
}

/// Start a new incremental Unix `.Z` (LZW) decoder using the default
/// limits.
pub fn new_lzw_decoder() -> Decoder {
  new_decoder(Lzw, limit.default())
}

/// Start a new incremental xz decoder using the default limits.
pub fn new_xz_decoder() -> Decoder {
  new_decoder(Xz, limit.default())
}

/// Start a new incremental zstd decoder using the default limits.
pub fn new_zstd_decoder() -> Decoder {
  new_decoder(Zstd, limit.default())
}

/// Start a new incremental brotli decoder using the default limits.
pub fn new_brotli_decoder() -> Decoder {
  new_decoder(Brotli, limit.default())
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
    Lz4 -> lz4.decode_with_limits(bytes: bytes, limits: decoder.limits)
    Snappy -> snappy.decode_with_limits(bytes: bytes, limits: decoder.limits)
    Bzip2 -> bzip2.decode_with_limits(bytes: bytes, limits: decoder.limits)
    Lzw -> lzw.decode_with_limits(bytes: bytes, limits: decoder.limits)
    Xz -> xz.decode_with_limits(bytes: bytes, limits: decoder.limits)
    Zstd -> zstd.decode_with_limits(bytes: bytes, limits: decoder.limits)
    Brotli -> brotli.decode_with_limits(bytes: bytes, limits: decoder.limits)
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

/// Opaque incremental encoder state.  Mirrors `Decoder`: callers
/// buffer plaintext chunks via `push_encoder` and pay the actual
/// compress cost once at `finish_encoder` time.  Buffering lets the
/// API stay symmetric with `Decoder` even though the underlying
/// codecs are still eager — when packkit grows true streaming
/// encoders the public surface won't have to change.
///
/// `buffered_bytes` is tracked so `push_encoder` can enforce
/// `max_input_bytes` incrementally against the input stream, matching
/// the decoder-side limit semantics.
pub opaque type Encoder {
  Encoder(
    kind: EncoderKind,
    buffer: List(BitArray),
    buffered_bytes: Int,
    limits: limit.Limits,
  )
}

type EncoderKind {
  EncDeflate
  EncZlib
  EncGzip
  EncLz4
  EncSnappy
  EncBzip2
  EncLzw
  EncXz
  EncZstd
  EncBrotli
}

/// Start a new incremental DEFLATE encoder using the default limits.
pub fn new_deflate_encoder() -> Encoder {
  new_encoder(EncDeflate, limit.default())
}

/// Start a new incremental zlib encoder using the default limits.
pub fn new_zlib_encoder() -> Encoder {
  new_encoder(EncZlib, limit.default())
}

/// Start a new incremental gzip encoder using the default limits.
/// The output uses `gzip.default_header()` — callers that need
/// per-stream metadata should keep using `gzip.encode` directly
/// until the streaming API grows an explicit header constructor.
pub fn new_gzip_encoder() -> Encoder {
  new_encoder(EncGzip, limit.default())
}

/// Start a new incremental LZ4 frame encoder using the default limits.
pub fn new_lz4_encoder() -> Encoder {
  new_encoder(EncLz4, limit.default())
}

/// Start a new incremental Snappy (framed) encoder using the default
/// limits.
pub fn new_snappy_encoder() -> Encoder {
  new_encoder(EncSnappy, limit.default())
}

/// Start a new incremental bzip2 encoder using the default limits.
pub fn new_bzip2_encoder() -> Encoder {
  new_encoder(EncBzip2, limit.default())
}

/// Start a new incremental Unix `.Z` (LZW) encoder using the default
/// limits.
pub fn new_lzw_encoder() -> Encoder {
  new_encoder(EncLzw, limit.default())
}

/// Start a new incremental xz encoder using the default limits.
pub fn new_xz_encoder() -> Encoder {
  new_encoder(EncXz, limit.default())
}

/// Start a new incremental zstd encoder using the default limits.
pub fn new_zstd_encoder() -> Encoder {
  new_encoder(EncZstd, limit.default())
}

/// Start a new incremental brotli encoder using the default limits.
pub fn new_brotli_encoder() -> Encoder {
  new_encoder(EncBrotli, limit.default())
}

fn new_encoder(kind: EncoderKind, limits: limit.Limits) -> Encoder {
  Encoder(kind: kind, buffer: [], buffered_bytes: 0, limits: limits)
}

/// Replace the limits used by an incremental encoder.
pub fn encoder_with_limits(
  encoder: Encoder,
  limits limits: limit.Limits,
) -> Encoder {
  Encoder(..encoder, limits: limits)
}

/// Append a chunk of plaintext bytes to the encoder, enforcing
/// `max_input_bytes` incrementally so an unbounded producer can't
/// trigger an unbounded `encode` allocation at `finish_encoder` time.
pub fn push_encoder(
  encoder: Encoder,
  chunk: BitArray,
) -> Result(Encoder, error.CodecError) {
  let chunk_size = bit_array.byte_size(chunk)
  let new_total = encoder.buffered_bytes + chunk_size
  case new_total > limit.max_input_bytes(encoder.limits) {
    True ->
      Error(error.CodecLimitExceeded(
        limit: "max_input_bytes",
        actual: new_total,
      ))
    False ->
      Ok(
        Encoder(
          ..encoder,
          buffer: [chunk, ..encoder.buffer],
          buffered_bytes: new_total,
        ),
      )
  }
}

/// Finalize the encoder and return the compressed payload.  Each
/// codec is invoked through its default `encode/1` form; advanced
/// per-codec options (gzip header metadata, deflate stored blocks,
/// lz4 content size, bzip2 level) are not exposed through the
/// streaming wrapper and remain accessible via the per-codec module.
pub fn finish_encoder(encoder: Encoder) -> Result(BitArray, error.CodecError) {
  let bytes = bit_array.concat(list.reverse(encoder.buffer))
  case encoder.kind {
    EncDeflate -> deflate.encode(bytes: bytes)
    EncZlib -> zlib.encode(bytes: bytes)
    EncGzip -> gzip.encode(bytes: bytes)
    EncLz4 -> lz4.encode(bytes: bytes)
    EncSnappy -> snappy.encode(bytes: bytes)
    EncBzip2 -> bzip2.encode(bytes: bytes)
    EncLzw -> lzw.encode(bytes: bytes)
    EncXz -> xz.encode(bytes: bytes)
    EncZstd -> zstd.encode(bytes: bytes)
    EncBrotli -> brotli.encode(bytes: bytes)
  }
}

/// Convenience helper that pushes every plaintext chunk through the
/// encoder in order and returns the final compressed payload.  Mirrors
/// `decode_chunks` so callers can drive both directions with the same
/// shape (list of input chunks → single output buffer).
pub fn encode_chunks(
  encoder encoder: Encoder,
  chunks chunks: List(BitArray),
) -> Result(BitArray, error.CodecError) {
  use fed <- result.try(feed_encoder_all(encoder, chunks))
  finish_encoder(fed)
}

fn feed_encoder_all(
  encoder: Encoder,
  chunks: List(BitArray),
) -> Result(Encoder, error.CodecError) {
  case chunks {
    [] -> Ok(encoder)
    [head, ..rest] -> {
      use next <- result.try(push_encoder(encoder, head))
      feed_encoder_all(next, rest)
    }
  }
}
