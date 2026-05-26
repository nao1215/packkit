import gleam/bit_array
import gleam/result
import gleeunit/should
import packkit/brotli
import packkit/bzip2
import packkit/deflate
import packkit/error
import packkit/gzip
import packkit/limit
import packkit/lz4
import packkit/lzw
import packkit/snappy
import packkit/stream
import packkit/xz
import packkit/zlib
import packkit/zstd

pub fn stream_deflate_matches_eager_test() -> Nil {
  let payload = <<"stream deflate fixture":utf8>>
  let assert Ok(compressed) = deflate.encode(bytes: payload)
  let chunks = split_in_thirds(compressed)
  let assert Ok(restored) =
    stream.decode_chunks(decoder: stream.new_deflate_decoder(), chunks: chunks)
  restored
  |> should.equal(payload)
}

pub fn stream_zlib_matches_eager_test() -> Nil {
  let payload = <<"stream zlib fixture":utf8>>
  let assert Ok(compressed) = zlib.encode(bytes: payload)
  let chunks = split_in_thirds(compressed)
  let assert Ok(restored) =
    stream.decode_chunks(decoder: stream.new_zlib_decoder(), chunks: chunks)
  restored
  |> should.equal(payload)
}

pub fn stream_gzip_matches_eager_test() -> Nil {
  let payload = <<"stream gzip fixture":utf8>>
  let assert Ok(compressed) =
    gzip.encode(bytes: payload, header: gzip.default_header())
  let chunks = split_in_thirds(compressed)
  let assert Ok(restored) =
    stream.decode_chunks(decoder: stream.new_gzip_decoder(), chunks: chunks)
  restored
  |> should.equal(payload)
}

pub fn stream_lz4_matches_eager_test() -> Nil {
  let payload = <<"stream lz4 fixture">>
  let assert Ok(compressed) = lz4.encode(bytes: payload)
  let chunks = split_in_thirds(compressed)
  let assert Ok(restored) =
    stream.decode_chunks(decoder: stream.new_lz4_decoder(), chunks: chunks)
  restored
  |> should.equal(payload)
}

pub fn stream_snappy_matches_eager_test() -> Nil {
  let payload = <<"stream snappy fixture">>
  let assert Ok(compressed) = snappy.encode(bytes: payload)
  let chunks = split_in_thirds(compressed)
  let assert Ok(restored) =
    stream.decode_chunks(decoder: stream.new_snappy_decoder(), chunks: chunks)
  restored
  |> should.equal(payload)
}

pub fn stream_bzip2_matches_eager_test() -> Nil {
  let payload = <<"stream bzip2 fixture">>
  let assert Ok(compressed) = bzip2.encode(bytes: payload)
  let chunks = split_in_thirds(compressed)
  let assert Ok(restored) =
    stream.decode_chunks(decoder: stream.new_bzip2_decoder(), chunks: chunks)
  restored
  |> should.equal(payload)
}

pub fn stream_lzw_matches_eager_test() -> Nil {
  let payload = <<"stream lzw fixture">>
  let assert Ok(compressed) = lzw.encode(bytes: payload)
  let chunks = split_in_thirds(compressed)
  let assert Ok(restored) =
    stream.decode_chunks(decoder: stream.new_lzw_decoder(), chunks: chunks)
  restored
  |> should.equal(payload)
}

pub fn stream_xz_matches_eager_test() -> Nil {
  let payload = <<"stream xz fixture">>
  let assert Ok(compressed) = xz.encode(bytes: payload)
  let chunks = split_in_thirds(compressed)
  let assert Ok(restored) =
    stream.decode_chunks(decoder: stream.new_xz_decoder(), chunks: chunks)
  restored
  |> should.equal(payload)
}

pub fn stream_zstd_matches_eager_test() -> Nil {
  let payload = <<"stream zstd fixture">>
  let assert Ok(compressed) = zstd.encode(bytes: payload)
  let chunks = split_in_thirds(compressed)
  let assert Ok(restored) =
    stream.decode_chunks(decoder: stream.new_zstd_decoder(), chunks: chunks)
  restored
  |> should.equal(payload)
}

pub fn stream_brotli_matches_eager_test() -> Nil {
  let payload = <<"stream brotli fixture">>
  let assert Ok(compressed) = brotli.encode(bytes: payload)
  let chunks = split_in_thirds(compressed)
  let assert Ok(restored) =
    stream.decode_chunks(decoder: stream.new_brotli_decoder(), chunks: chunks)
  restored
  |> should.equal(payload)
}

pub fn stream_chunk_boundary_invariance_test() -> Nil {
  // Splitting the encoded byte stream at different boundaries must
  // produce the same plaintext.  This pins down the buffered
  // implementation against off-by-one chunk-stitching bugs.
  let payload = <<
    "chunk boundary invariance fixture — long enough to span splits":utf8,
  >>
  let assert Ok(compressed) = zlib.encode(bytes: payload)

  let assert Ok(width_one) =
    stream.decode_chunks(
      decoder: stream.new_zlib_decoder(),
      chunks: split_at_width(compressed, 1),
    )
  let assert Ok(width_three) =
    stream.decode_chunks(
      decoder: stream.new_zlib_decoder(),
      chunks: split_at_width(compressed, 3),
    )
  let assert Ok(width_seven) =
    stream.decode_chunks(
      decoder: stream.new_zlib_decoder(),
      chunks: split_at_width(compressed, 7),
    )

  width_one
  |> should.equal(payload)
  width_three
  |> should.equal(payload)
  width_seven
  |> should.equal(payload)
}

pub fn stream_push_enforces_max_input_bytes_test() -> Nil {
  // Regression: `push` used to swallow arbitrarily many chunks before
  // `finish` ever checked `max_input_bytes`.  Now the limit is enforced
  // chunk-by-chunk so a hostile producer can't pile bytes into the
  // decoder past the budget.
  let tight =
    stream.new_deflate_decoder()
    |> stream.with_limits(
      limit.default() |> limit.with_max_input_bytes(bytes: 4),
    )
  case stream.push(tight, <<"abcde":utf8>>) {
    Error(error.CodecLimitExceeded(limit: "max_input_bytes", actual: 5)) -> Nil
    _ -> should.fail()
  }
}

pub fn stream_push_enforces_limit_across_chunks_test() -> Nil {
  // Even if no single chunk exceeds the limit, the running buffered
  // total must trip it.
  let decoder =
    stream.new_gzip_decoder()
    |> stream.with_limits(
      limit.default() |> limit.with_max_input_bytes(bytes: 4),
    )
  let assert Ok(decoder) = stream.push(decoder, <<"ab":utf8>>)
  let assert Ok(decoder) = stream.push(decoder, <<"cd":utf8>>)
  case stream.push(decoder, <<"e":utf8>>) {
    Error(error.CodecLimitExceeded(limit: "max_input_bytes", actual: 5)) -> Nil
    _ -> should.fail()
  }
}

pub fn stream_decode_chunks_propagates_limit_error_test() -> Nil {
  // The convenience helper must surface the same typed error rather
  // than silently dropping over-limit chunks.
  let decoder =
    stream.new_zlib_decoder()
    |> stream.with_limits(
      limit.default() |> limit.with_max_input_bytes(bytes: 3),
    )
  case
    stream.decode_chunks(decoder: decoder, chunks: [
      <<"ab":utf8>>,
      <<"cd":utf8>>,
    ])
  {
    Error(error.CodecLimitExceeded(limit: "max_input_bytes", actual: 4)) -> Nil
    _ -> should.fail()
  }
}

pub fn gzip_decoder_push_enforces_max_input_bytes_test() -> Nil {
  // The codec-specific decoder must apply the same incremental check.
  let decoder =
    gzip.new_decoder_with_limits(
      limit.default() |> limit.with_max_input_bytes(bytes: 4),
    )
  case gzip.push(decoder, <<"abcde":utf8>>) {
    Error(error.CodecLimitExceeded(limit: "max_input_bytes", actual: 5)) -> Nil
    _ -> should.fail()
  }
}

fn split_at_width(bytes: BitArray, width: Int) -> List(BitArray) {
  split_at_width_loop(bytes, width, bit_array.byte_size(bytes), [])
}

fn split_at_width_loop(
  bytes: BitArray,
  width: Int,
  remaining: Int,
  acc: List(BitArray),
) -> List(BitArray) {
  case remaining {
    0 -> list_reverse(acc, [])
    n -> {
      let chunk_size = case n > width {
        True -> width
        False -> n
      }
      let offset = bit_array.byte_size(bytes) - remaining
      let assert Ok(chunk) = bit_array.slice(bytes, offset, chunk_size)
      split_at_width_loop(bytes, width, remaining - chunk_size, [chunk, ..acc])
    }
  }
}

fn list_reverse(values: List(a), acc: List(a)) -> List(a) {
  case values {
    [] -> acc
    [head, ..rest] -> list_reverse(rest, [head, ..acc])
  }
}

fn split_in_thirds(bytes: BitArray) -> List(BitArray) {
  let size = bit_array.byte_size(bytes)
  let part = size / 3
  case size {
    0 -> [bytes]
    _ -> {
      let assert Ok(a) = bit_array.slice(bytes, 0, part)
      let assert Ok(b) = bit_array.slice(bytes, part, part)
      let assert Ok(c) = bit_array.slice(bytes, part * 2, size - 2 * part)
      [a, b, c]
    }
  }
}

// -- streaming encoders ----------------------------------------------
//
// The encoder API mirrors the decoder API: callers buffer plaintext
// chunks via `push_encoder` and pay the actual encode cost once at
// `finish_encoder` time.  Until the underlying codecs grow truly
// incremental encoders, the API contract is just "the output equals
// what the one-shot `<codec>.encode` would produce for the
// catenated input".  The round-trip property is the stronger check:
// stream-encoded → one-shot decode should reproduce the original
// payload byte-for-byte.

fn stream_encode_then_decode(
  encoder: stream.Encoder,
  chunks: List(BitArray),
  decode: fn(BitArray) -> Result(BitArray, error.CodecError),
) -> Result(BitArray, error.CodecError) {
  use encoded <- result.try(stream.encode_chunks(
    encoder: encoder,
    chunks: chunks,
  ))
  decode(encoded)
}

pub fn stream_encoder_deflate_roundtrip_test() -> Nil {
  let payload = <<"deflate stream encoder round trip payload":utf8>>
  let chunks = split_in_thirds(payload)
  let assert Ok(decoded) =
    stream_encode_then_decode(
      stream.new_deflate_encoder(),
      chunks,
      deflate.decode(bytes: _),
    )
  decoded |> should.equal(payload)
}

pub fn stream_encoder_zlib_roundtrip_test() -> Nil {
  let payload = <<"zlib stream encoder round trip payload":utf8>>
  let chunks = split_in_thirds(payload)
  let assert Ok(decoded) =
    stream_encode_then_decode(stream.new_zlib_encoder(), chunks, zlib.decode(
      bytes: _,
    ))
  decoded |> should.equal(payload)
}

pub fn stream_encoder_gzip_roundtrip_test() -> Nil {
  let payload = <<"gzip stream encoder round trip payload":utf8>>
  let chunks = split_in_thirds(payload)
  let assert Ok(encoded) =
    stream.encode_chunks(encoder: stream.new_gzip_encoder(), chunks: chunks)
  let assert Ok(decoded) = gzip.decode(bytes: encoded)
  decoded.payload |> should.equal(payload)
}

pub fn stream_encoder_lz4_roundtrip_test() -> Nil {
  let payload = <<"lz4 stream encoder round trip payload":utf8>>
  let chunks = split_in_thirds(payload)
  let assert Ok(decoded) =
    stream_encode_then_decode(stream.new_lz4_encoder(), chunks, lz4.decode(
      bytes: _,
    ))
  decoded |> should.equal(payload)
}

pub fn stream_encoder_snappy_roundtrip_test() -> Nil {
  let payload = <<"snappy stream encoder round trip payload":utf8>>
  let chunks = split_in_thirds(payload)
  let assert Ok(decoded) =
    stream_encode_then_decode(
      stream.new_snappy_encoder(),
      chunks,
      snappy.decode(bytes: _),
    )
  decoded |> should.equal(payload)
}

pub fn stream_encoder_bzip2_roundtrip_test() -> Nil {
  let payload = <<"bzip2 stream encoder round trip payload":utf8>>
  let chunks = split_in_thirds(payload)
  let assert Ok(decoded) =
    stream_encode_then_decode(stream.new_bzip2_encoder(), chunks, bzip2.decode(
      bytes: _,
    ))
  decoded |> should.equal(payload)
}

pub fn stream_encoder_lzw_roundtrip_test() -> Nil {
  let payload = <<"lzw stream encoder round trip payload":utf8>>
  let chunks = split_in_thirds(payload)
  let assert Ok(decoded) =
    stream_encode_then_decode(stream.new_lzw_encoder(), chunks, lzw.decode(
      bytes: _,
    ))
  decoded |> should.equal(payload)
}

pub fn stream_encoder_xz_roundtrip_test() -> Nil {
  let payload = <<"xz stream encoder round trip payload":utf8>>
  let chunks = split_in_thirds(payload)
  let assert Ok(decoded) =
    stream_encode_then_decode(stream.new_xz_encoder(), chunks, xz.decode(
      bytes: _,
    ))
  decoded |> should.equal(payload)
}

pub fn stream_encoder_zstd_roundtrip_test() -> Nil {
  let payload = <<"zstd stream encoder round trip payload":utf8>>
  let chunks = split_in_thirds(payload)
  let assert Ok(decoded) =
    stream_encode_then_decode(stream.new_zstd_encoder(), chunks, zstd.decode(
      bytes: _,
    ))
  decoded |> should.equal(payload)
}

pub fn stream_encoder_brotli_roundtrip_test() -> Nil {
  let payload = <<"brotli stream encoder round trip payload":utf8>>
  let chunks = split_in_thirds(payload)
  let assert Ok(decoded) =
    stream_encode_then_decode(
      stream.new_brotli_encoder(),
      chunks,
      brotli.decode(bytes: _),
    )
  decoded |> should.equal(payload)
}

pub fn stream_encoder_matches_one_shot_encode_test() -> Nil {
  // The streaming encoder is just a buffer: the output of
  // `encode_chunks` MUST equal `<codec>.encode(catenated_input)`
  // byte-for-byte.  If this stops being true the streaming wrapper
  // has started doing something the one-shot path doesn't, which is
  // an API contract break worth catching.
  let payload = <<"matches one-shot encode test payload":utf8>>
  let chunks = split_in_thirds(payload)
  let assert Ok(one_shot) = deflate.encode(bytes: payload)
  let assert Ok(streamed) =
    stream.encode_chunks(encoder: stream.new_deflate_encoder(), chunks: chunks)
  streamed |> should.equal(one_shot)
}

pub fn stream_encoder_push_enforces_max_input_bytes_test() -> Nil {
  // `push_encoder` must enforce `max_input_bytes` incrementally so a
  // hostile producer can't feed an unbounded plaintext stream and
  // trigger an unbounded `encode` allocation at `finish_encoder`
  // time.  Tight limit (16) + first chunk slightly larger (20 bytes)
  // = typed `CodecLimitExceeded`.
  let tight = limit.default() |> limit.with_max_input_bytes(bytes: 16)
  let encoder =
    stream.new_deflate_encoder() |> stream.encoder_with_limits(limits: tight)
  let chunk = <<"twenty-byte payload!":utf8>>
  case stream.push_encoder(encoder, chunk) {
    Error(error.CodecLimitExceeded(limit: "max_input_bytes", actual: _)) -> Nil
    _ -> should.fail()
  }
}
