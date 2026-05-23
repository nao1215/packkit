import gleam/bit_array
import gleeunit/should
import packkit/deflate
import packkit/gzip
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
