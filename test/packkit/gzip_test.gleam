import gleam/bit_array
import gleam/int
import gleam/option.{None, Some}
import gleeunit/should
import packkit/checksum
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

  let assert Ok(bytes) = gzip.encode_with_header(bytes: payload, header: header)
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
  let assert Ok(bytes) = gzip.encode_with_header(bytes: payload, header: header)
  let assert Ok(decoded) = gzip.decode(bytes: bytes)
  gzip.modified_at_unix(decoded.header)
  |> should.equal(Some(1_234_567_890))
}

pub fn decode_with_limits_preserves_mtime_test() -> Nil {
  let header = gzip.default_header() |> gzip.with_modified_at(unix_seconds: 42)
  let payload = <<"mtime via decode_with_limits":utf8>>
  let assert Ok(bytes) = gzip.encode_with_header(bytes: payload, header: header)
  let assert Ok(decoded) =
    gzip.decode_with_limits(bytes: bytes, limits: limit.default())
  gzip.modified_at_unix(decoded.header)
  |> should.equal(Some(42))
}

pub fn decode_treats_zero_mtime_as_unset_test() -> Nil {
  // RFC 1952 §2.3.1: MTIME=0 means "no time stamp available".  We surface
  // that as `None` rather than `Some(0)` so callers can tell the cases apart.
  let assert Ok(bytes) = gzip.encode(bytes: <<"no mtime":utf8>>)
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
  let assert Ok(encoded) = gzip.encode(bytes: payload)
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
  let assert Ok(encoded) =
    gzip.encode_with_header(bytes: payload, header: header)
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
  let assert Ok(encoded) = gzip.encode(bytes: payload)
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
  let assert Ok(member_a) = gzip.encode(bytes: <<"alpha-":utf8>>)
  let assert Ok(member_b) = gzip.encode(bytes: <<"bravo-":utf8>>)
  let assert Ok(member_c) = gzip.encode(bytes: <<"charlie":utf8>>)
  let combined = bit_array.concat([member_a, member_b, member_c])
  let assert Ok(decoded) = gzip.decode(bytes: combined)
  decoded.payload
  |> should.equal(<<"alpha-bravo-charlie":utf8>>)
}

pub fn decode_multi_member_via_payload_helper_test() -> Nil {
  let assert Ok(member_a) = gzip.encode(bytes: <<"x":utf8>>)
  let assert Ok(member_b) = gzip.encode(bytes: <<"y":utf8>>)
  let assert Ok(plain) =
    gzip.decode_payload(bytes: bit_array.concat([member_a, member_b]))
  plain
  |> should.equal(<<"xy":utf8>>)
}

pub fn decode_multi_member_enforces_max_output_bytes_test() -> Nil {
  // Each member's deflate stream individually fits inside
  // `max_output_bytes`, but the catenation of N members can grow
  // up to N × max_output_bytes if the per-member check is the
  // only guard.  The decoder must reject as soon as the
  // accumulated payload exceeds the limit so that adversarial
  // multi-member archives cannot OOM the host.
  let payload = <<"twenty-byte-payload!":utf8>>
  // 20 bytes per member; 3 members = 60 bytes total.
  let assert Ok(member) = gzip.encode(bytes: payload)
  let combined = bit_array.concat([member, member, member])
  // Limit allows up to 40 output bytes, so member 1 fits, member
  // 2 pushes the running total to 40, member 3 should overflow.
  let restrictive_limits =
    limit.default()
    |> limit.with_max_output_bytes(bytes: 40)
  case gzip.decode_with_limits(bytes: combined, limits: restrictive_limits) {
    Error(error.CodecLimitExceeded(limit: "max_output_bytes", actual: _)) -> Nil
    _ -> should.fail()
  }
}

pub fn fextra_roundtrip_single_subfield_test() -> Nil {
  // BGZF (bgzipped block format) embeds the block size in an
  // FEXTRA subfield with SI1='B' (0x42), SI2='C' (0x43).  The
  // encoder must accept and round-trip such metadata.
  let bgzf_subfield =
    gzip.Subfield(id_1: 0x42, id_2: 0x43, data: <<0x00, 0x10>>)
  let header =
    gzip.default_header()
    |> gzip.with_extra(subfields: [bgzf_subfield])
  let payload = <<"bgzf-test-payload":utf8>>

  let assert Ok(bytes) = gzip.encode_with_header(bytes: payload, header: header)
  let assert Ok(decoded) = gzip.decode(bytes: bytes)
  decoded.payload
  |> should.equal(payload)
  gzip.extra(decoded.header)
  |> should.equal([bgzf_subfield])
}

pub fn fextra_roundtrip_multiple_subfields_test() -> Nil {
  let s1 = gzip.Subfield(id_1: 0x42, id_2: 0x43, data: <<0xCA, 0xFE>>)
  let s2 = gzip.Subfield(id_1: 0x52, id_2: 0x72, data: <<"hello":utf8>>)
  let header =
    gzip.default_header()
    |> gzip.with_extra(subfields: [s1, s2])
  let payload = <<"multi-subfield":utf8>>

  let assert Ok(bytes) = gzip.encode_with_header(bytes: payload, header: header)
  let assert Ok(decoded) = gzip.decode(bytes: bytes)
  decoded.payload
  |> should.equal(payload)
  gzip.extra(decoded.header)
  |> should.equal([s1, s2])
}

pub fn fextra_roundtrip_with_name_and_comment_test() -> Nil {
  // Exercise the encoder path where every optional flag fires.
  let subfield = gzip.Subfield(id_1: 0x41, id_2: 0x70, data: <<>>)
  let header =
    gzip.default_header()
    |> gzip.with_extra(subfields: [subfield])
    |> gzip.with_name(name: "data.txt")
    |> gzip.with_comment(comment: "all fields populated")
  let payload = <<"all-fields":utf8>>
  let assert Ok(bytes) = gzip.encode_with_header(bytes: payload, header: header)
  let assert Ok(decoded) = gzip.decode(bytes: bytes)
  decoded.payload
  |> should.equal(payload)
  gzip.name(decoded.header)
  |> should.equal(Some("data.txt"))
  gzip.comment(decoded.header)
  |> should.equal(Some("all fields populated"))
  gzip.extra(decoded.header)
  |> should.equal([subfield])
}

pub fn fextra_default_header_has_empty_extra_test() -> Nil {
  gzip.extra(gzip.default_header())
  |> should.equal([])
}

// -- RFC 1952 §2.3.1 compliance --------------------------------------------

/// Reserved FLG bits (0x20 / 0x40 / 0x80) MUST be zero per RFC 1952.
/// Earlier revisions of `gzip.decode` happily accepted any flag value
/// and would silently misinterpret a future extension as if it were a
/// vanilla gzip stream — added an explicit guard, pin it as a test.
pub fn rejects_reserved_flg_bit_test() -> Nil {
  // Minimal header carrying just a reserved bit set.  CM is deflate
  // and the payload is irrelevant because the guard fires before any
  // DEFLATE byte is parsed.
  let header_with_reserved_bit = <<
    0x1F, 0x8B, 0x08, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF,
  >>
  case gzip.decode(bytes: header_with_reserved_bit) {
    Error(error.CodecInvalidData(message: "gzip reserved FLG bits set")) -> Nil
    _ -> should.fail()
  }
}

/// RFC 1952 §2.3.1: when FLG.FHCRC is set, the 2-byte field is the
/// CRC-16 (low two bytes of the CRC-32) of the header bytes up to but
/// not including the CRC-16 itself.  The decoder used to skip those
/// two bytes without verifying them; this test pins the verified path
/// in both the accept and reject directions.
pub fn fhcrc_accepts_valid_and_rejects_corrupt_test() -> Nil {
  // Minimal header for an empty DEFLATE stored block, with FHCRC set.
  let header_for_crc = <<
    0x1F, 0x8B, 0x08, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF,
  >>
  let crc16 = int.bitwise_and(checksum.crc32(data: header_for_crc), 0xFFFF)
  let crc16_bytes = <<crc16:size(16)-little>>
  // DEFLATE empty stored block: bfinal=1 btype=00 → 0x01 then LEN=0 then ~LEN=0xFFFF.
  let deflate_empty_stored = <<0x01, 0x00, 0x00, 0xFF, 0xFF>>
  // Empty payload trailer: CRC32 = 0, ISIZE = 0.
  let trailer = <<0:size(64)>>

  let good =
    bit_array.concat([
      header_for_crc,
      crc16_bytes,
      deflate_empty_stored,
      trailer,
    ])
  let assert Ok(decoded) = gzip.decode(bytes: good)
  decoded.payload
  |> should.equal(<<>>)

  // Flip the low byte of the CRC-16 — must fail with the typed
  // mismatch message rather than silently propagating.
  let bad_crc16_bytes = <<
    int.bitwise_exclusive_or(int.bitwise_and(crc16, 0xFF), 0xFF),
    int.bitwise_shift_right(crc16, 8),
  >>
  let bad =
    bit_array.concat([
      header_for_crc,
      bad_crc16_bytes,
      deflate_empty_stored,
      trailer,
    ])
  case gzip.decode(bytes: bad) {
    Error(error.CodecInvalidData(message: "gzip header CRC16 mismatch")) -> Nil
    _ -> should.fail()
  }
}

/// RFC 1952 §2.3.1 specifies FNAME / FCOMMENT as ISO 8859-1 (LATIN-1).
/// Earlier revisions decoded as UTF-8 and rejected RFC-conformant
/// Latin-1 names containing bytes 0x80..0xFF.  The decoder now tries
/// UTF-8 first (the common modern case) and falls back to a 1-to-1
/// byte-to-codepoint Latin-1 mapping so a stream produced by an older
/// `gzip` honouring the spec literally still decodes.
pub fn fname_latin1_decodes_test() -> Nil {
  // Header with FLG.FNAME, name = "café" in ISO-8859-1 (the trailing
  // `é` is byte 0xE9 — not valid as a standalone UTF-8 sequence).
  let header_fixed = <<
    0x1F, 0x8B, 0x08, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF,
  >>
  let fname_latin1 = <<0x63, 0x61, 0x66, 0xE9, 0x00>>
  let deflate_empty_stored = <<0x01, 0x00, 0x00, 0xFF, 0xFF>>
  let trailer = <<0:size(64)>>

  let stream =
    bit_array.concat([header_fixed, fname_latin1, deflate_empty_stored, trailer])

  let assert Ok(decoded) = gzip.decode(bytes: stream)
  // UTF-8 string "café" — U+00E9 encodes to bytes C3 A9.
  gzip.name(decoded.header)
  |> should.equal(Some("café"))
  decoded.payload
  |> should.equal(<<>>)
}
