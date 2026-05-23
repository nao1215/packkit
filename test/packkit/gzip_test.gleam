import gleam/bit_array
import gleam/option.{None, Some}
import gleeunit/should
import packkit/error
import packkit/gzip

pub fn decode_python_gzip_hello_test() -> Nil {
  // Produced by Python's gzip.GzipFile(mtime=0).write(b"hello packkit").
  let compressed = <<
    0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xFF, 0xCB, 0x48, 0xCD,
    0xC9, 0xC9, 0x57, 0x28, 0x48, 0x4C, 0xCE, 0xCE, 0xCE, 0x2C, 0x01, 0x00, 0xCA,
    0xA8, 0x6C, 0xBA, 0x0D, 0x00, 0x00, 0x00,
  >>
  let assert Ok(decoded) = gzip.decode(bytes: compressed)
  decoded.payload
  |> should.equal(<<"hello packkit":utf8>>)
  gzip.name(decoded.header)
  |> should.equal(None)
}

pub fn roundtrip_with_metadata_test() -> Nil {
  let header =
    gzip.default_header()
    |> gzip.with_name(name: "data.txt")
    |> gzip.with_comment(comment: "packkit test")
    |> gzip.with_modified_at(unix_seconds: 1_700_000_000)
  let payload = <<"This is a longer body for gzip round-trip testing.":utf8>>

  let assert Ok(bytes) = gzip.encode(bytes: payload, header: header)
  let assert Ok(decoded) = gzip.decode(bytes: bytes)

  decoded.payload
  |> should.equal(payload)
  gzip.name(decoded.header)
  |> should.equal(Some("data.txt"))
  gzip.comment(decoded.header)
  |> should.equal(Some("packkit test"))
}

pub fn rejects_bad_magic_test() -> Nil {
  case gzip.decode(bytes: <<0xCA, 0xFE, 0xBA, 0xBE>>) {
    Error(error.CodecInvalidData(_)) -> Nil
    _ -> should.fail()
  }
}

pub fn decode_payload_returns_bitarray_for_parity_test() -> Nil {
  // decode_payload mirrors the (BitArray) signature every other codec
  // exposes — no need to reach into a Decoded record for the common path.
  let payload = <<"parity check":utf8>>
  let assert Ok(encoded) =
    gzip.encode(bytes: payload, header: gzip.default_header())
  let assert Ok(plain) = gzip.decode_payload(bytes: encoded)
  plain
  |> should.equal(payload)
}

pub fn with_name_checked_rejects_embedded_nul_test() -> Nil {
  // gzip terminates FNAME at the first NUL.  A name containing NUL
  // would silently truncate on the round-trip, so the checked
  // builder must reject it with the typed `HeaderNameContainsNul`.
  gzip.default_header()
  |> gzip.with_name_checked(name: "before\u{0000}after")
  |> should.equal(Error(gzip.HeaderNameContainsNul))
}

pub fn with_comment_checked_rejects_embedded_nul_test() -> Nil {
  gzip.default_header()
  |> gzip.with_comment_checked(comment: "x\u{0000}y")
  |> should.equal(Error(gzip.HeaderCommentContainsNul))
}

pub fn with_name_checked_accepts_nul_free_name_test() -> Nil {
  let assert Ok(header) =
    gzip.default_header() |> gzip.with_name_checked(name: "valid.txt")
  let payload = <<"checked-name round trip":utf8>>
  let assert Ok(encoded) = gzip.encode(bytes: payload, header: header)
  let assert Ok(decoded) = gzip.decode(bytes: encoded)
  gzip.name(decoded.header)
  |> should.equal(Some("valid.txt"))
}

pub fn streaming_decoder_round_trips_test() -> Nil {
  // gzip.new_decoder / push / finish now buffers chunks and runs the
  // eager decoder at finish time.  Regression for the period when
  // both push and finish returned `CodecNotImplemented`.
  let payload = <<"streaming gzip round trip":utf8>>
  let assert Ok(encoded) =
    gzip.encode(bytes: payload, header: gzip.default_header())
  let half = 6
  let total = bit_array.byte_size(encoded)
  let assert Ok(first_chunk) = bit_array.slice(encoded, 0, half)
  let assert Ok(second_chunk) = bit_array.slice(encoded, half, total - half)
  let decoder = gzip.new_decoder()
  let assert Ok(#(decoder, _)) = gzip.push(decoder, first_chunk)
  let assert Ok(#(decoder, _)) = gzip.push(decoder, second_chunk)
  let assert Ok([chunk]) = gzip.finish(decoder)
  chunk
  |> should.equal(payload)
}
