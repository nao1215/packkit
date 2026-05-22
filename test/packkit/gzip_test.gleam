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
