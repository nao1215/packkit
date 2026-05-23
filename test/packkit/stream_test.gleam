import gleam/bit_array
import gleeunit/should
import packkit/deflate
import packkit/error
import packkit/gzip
import packkit/limit
import packkit/stream
import packkit/zlib

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
