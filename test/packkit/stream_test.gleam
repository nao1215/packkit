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
