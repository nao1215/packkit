import gleam/bit_array
import gleam/option.{None, Some}
import gleeunit/should
import packkit/error
import packkit/gzip
import packkit/limit

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
  gzip.modified_at_unix(decoded.header)
  |> should.equal(Some(1_700_000_000))
}

pub fn decode_preserves_mtime_test() -> Nil {
  // Regression: the decoder used to drop the MTIME field on the floor,
  // so `with_modified_at` round-trips were silently lossy.
  let header =
    gzip.default_header() |> gzip.with_modified_at(unix_seconds: 1_234_567_890)
  let payload = <<"mtime round trip":utf8>>
  let assert Ok(bytes) = gzip.encode(bytes: payload, header: header)
  let assert Ok(decoded) = gzip.decode(bytes: bytes)
  gzip.modified_at_unix(decoded.header)
  |> should.equal(Some(1_234_567_890))
}

pub fn decode_with_limits_preserves_mtime_test() -> Nil {
  let header = gzip.default_header() |> gzip.with_modified_at(unix_seconds: 42)
  let payload = <<"mtime via decode_with_limits":utf8>>
  let assert Ok(bytes) = gzip.encode(bytes: payload, header: header)
  let assert Ok(decoded) =
    gzip.decode_with_limits(bytes: bytes, limits: limit.default())
  gzip.modified_at_unix(decoded.header)
  |> should.equal(Some(42))
}

pub fn decode_treats_zero_mtime_as_unset_test() -> Nil {
  // RFC 1952 §2.3.1: MTIME=0 means "no time stamp available".  We surface
  // that as `None` rather than `Some(0)` so callers can tell the cases apart.
  let assert Ok(bytes) =
    gzip.encode(bytes: <<"no mtime":utf8>>, header: gzip.default_header())
  let assert Ok(decoded) = gzip.decode(bytes: bytes)
  gzip.modified_at_unix(decoded.header)
  |> should.equal(None)
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

pub fn with_modified_at_checked_rejects_negative_test() -> Nil {
  gzip.default_header()
  |> gzip.with_modified_at_checked(unix_seconds: -1)
  |> should.equal(Error(gzip.HeaderModifiedAtOutOfRange(value: -1)))
}

pub fn with_modified_at_checked_rejects_above_u32_test() -> Nil {
  gzip.default_header()
  |> gzip.with_modified_at_checked(unix_seconds: 0x1_0000_0000)
  |> should.equal(Error(gzip.HeaderModifiedAtOutOfRange(value: 0x1_0000_0000)))
}

pub fn with_modified_at_checked_accepts_u32_boundary_test() -> Nil {
  let assert Ok(header) =
    gzip.default_header()
    |> gzip.with_modified_at_checked(unix_seconds: 0xFFFFFFFF)
  gzip.modified_at_unix(header)
  |> should.equal(Some(0xFFFFFFFF))
}

pub fn streaming_decoder_round_trips_test() -> Nil {
  // gzip.new_decoder / push / finish now buffers chunks and runs the
  // eager decoder at finish time.  The shape mirrors `packkit/stream`
  // exactly — push returns `Result(Decoder, _)` and finish returns
  // `Result(BitArray, _)`.
  let payload = <<"streaming gzip round trip":utf8>>
  let assert Ok(encoded) =
    gzip.encode(bytes: payload, header: gzip.default_header())
  let half = 6
  let total = bit_array.byte_size(encoded)
  let assert Ok(first_chunk) = bit_array.slice(encoded, 0, half)
  let assert Ok(second_chunk) = bit_array.slice(encoded, half, total - half)
  let decoder = gzip.new_decoder()
  let assert Ok(decoder) = gzip.push(decoder, first_chunk)
  let assert Ok(decoder) = gzip.push(decoder, second_chunk)
  let assert Ok(chunk) = gzip.finish(decoder)
  chunk
  |> should.equal(payload)
}

pub fn decode_multi_member_concatenated_test() -> Nil {
  // RFC 1952 §2.2 explicitly allows a gzip stream to consist of
  // multiple concatenated members (e.g. `cat a.gz b.gz > c.gz`).
  // The decoder must concatenate the per-member payloads.
  let assert Ok(member_a) =
    gzip.encode(bytes: <<"alpha-":utf8>>, header: gzip.default_header())
  let assert Ok(member_b) =
    gzip.encode(bytes: <<"bravo-":utf8>>, header: gzip.default_header())
  let assert Ok(member_c) =
    gzip.encode(bytes: <<"charlie":utf8>>, header: gzip.default_header())
  let combined = bit_array.concat([member_a, member_b, member_c])
  let assert Ok(decoded) = gzip.decode(bytes: combined)
  decoded.payload
  |> should.equal(<<"alpha-bravo-charlie":utf8>>)
}

pub fn decode_multi_member_via_payload_helper_test() -> Nil {
  let assert Ok(member_a) =
    gzip.encode(bytes: <<"x":utf8>>, header: gzip.default_header())
  let assert Ok(member_b) =
    gzip.encode(bytes: <<"y":utf8>>, header: gzip.default_header())
  let assert Ok(plain) =
    gzip.decode_payload(bytes: bit_array.concat([member_a, member_b]))
  plain
  |> should.equal(<<"xy":utf8>>)
}
