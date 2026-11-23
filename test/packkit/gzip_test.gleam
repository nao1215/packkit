import gleam/bit_array
import gleam/int
import gleam/option.{None, Some}
import gleeunit/should
import packkit
import packkit/codec
import packkit/gzip
import packkit/internal/checksum
import packkit/limit

const empty =
  gzip.Header(name: None, comment: None, modified_at: None, extra: [])

pub fn decode_python_gzip_hello_test() -> Nil {
  // Produced by Python's gzip.GzipFile(mtime=0).write(b"hello packkit").
  let compressed = <<
    0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xFF, 0xCB, 0x48, 0xCD,
    0xC9, 0xC9, 0x57, 0x28, 0x48, 0x4C, 0xCE, 0xCE, 0xCE, 0x2C, 0x01, 0x00, 0xCA,
    0xA8, 0x6C, 0xBA, 0x0D, 0x00, 0x00, 0x00,
  >>
  let assert Ok(decoded) = gzip.decode(compressed, limits: limit.default())
  decoded.payload
  |> should.equal(<<"hello packkit":utf8>>)
  decoded.header.name
  |> should.equal(None)
}

pub fn roundtrip_with_metadata_test() -> Nil {
  let header =
    gzip.Header(
      name: Some("data.txt"),
      comment: Some("packkit test"),
      modified_at: Some(1_700_000_000),
      extra: [],
    )
  let payload = <<"This is a longer body for gzip round-trip testing.":utf8>>

  let assert Ok(bytes) = gzip.encode(payload, header: header)
  let assert Ok(decoded) = gzip.decode(bytes, limits: limit.default())

  decoded.payload
  |> should.equal(payload)
  decoded.header.name
  |> should.equal(Some("data.txt"))
  decoded.header.comment
  |> should.equal(Some("packkit test"))
  decoded.header.modified_at
  |> should.equal(Some(1_700_000_000))
}

pub fn decode_preserves_mtime_test() -> Nil {
  // Regression: the decoder used to drop the MTIME field on the floor,
  // so `with_modified_at` round-trips were silently lossy.
  let header =
    gzip.Header(
      name: None,
      comment: None,
      modified_at: Some(1_234_567_890),
      extra: [],
    )
  let payload = <<"mtime round trip":utf8>>
  let assert Ok(bytes) = gzip.encode(payload, header: header)
  let assert Ok(decoded) = gzip.decode(bytes, limits: limit.default())
  decoded.header.modified_at
  |> should.equal(Some(1_234_567_890))
}

pub fn decode_treats_zero_mtime_as_unset_test() -> Nil {
  // RFC 1952 §2.3.1: MTIME=0 means "no time stamp available".  We surface
  // that as `None` rather than `Some(0)` so callers can tell the cases apart.
  let bytes = gzip.encode_without_header(<<"no mtime":utf8>>)
  let assert Ok(decoded) = gzip.decode(bytes, limits: limit.default())
  decoded.header.modified_at
  |> should.equal(None)
}

pub fn rejects_bad_magic_test() -> Nil {
  case gzip.decode(<<0xCA, 0xFE, 0xBA, 0xBE>>, limits: limit.default()) {
    Error(codec.InvalidData(_)) -> Nil
    _ -> should.fail()
  }
}

pub fn decode_payload_returns_bitarray_for_parity_test() -> Nil {
  // decode_payload mirrors the (BitArray) signature every other codec
  // exposes — no need to reach into a Decoded record for the common path.
  let payload = <<"parity check":utf8>>
  let encoded = gzip.encode_without_header(payload)
  let assert Ok(plain) = packkit.decompress(encoded, with: codec.Gzip)
  plain
  |> should.equal(payload)
}

pub fn encode_rejects_name_with_nul_test() -> Nil {
  // gzip terminates FNAME at the first NUL, so a name containing one
  // would come back truncated.
  gzip.encode(
    <<>>,
    header: gzip.Header(..empty, name: Some("before\u{0000}after")),
  )
  |> should.equal(Error(gzip.NameContainsNul))
}

pub fn encode_rejects_comment_with_nul_test() -> Nil {
  gzip.encode(<<>>, header: gzip.Header(..empty, comment: Some("x\u{0000}y")))
  |> should.equal(Error(gzip.CommentContainsNul))
}

pub fn encode_rejects_negative_mtime_test() -> Nil {
  gzip.encode(<<>>, header: gzip.Header(..empty, modified_at: Some(-1)))
  |> should.equal(Error(gzip.ModifiedAtOutOfRange(value: -1)))
}

pub fn encode_rejects_mtime_above_u32_test() -> Nil {
  gzip.encode(
    <<>>,
    header: gzip.Header(..empty, modified_at: Some(0x1_0000_0000)),
  )
  |> should.equal(Error(gzip.ModifiedAtOutOfRange(value: 0x1_0000_0000)))
}

pub fn encode_accepts_mtime_at_u32_boundary_test() -> Nil {
  let assert Ok(bytes) =
    gzip.encode(
      <<>>,
      header: gzip.Header(..empty, modified_at: Some(0xFFFFFFFF)),
    )
  let assert Ok(decoded) = gzip.decode(bytes, limits: limit.default())
  decoded.header.modified_at
  |> should.equal(Some(0xFFFFFFFF))
}

pub fn encode_rejects_oversized_subfield_test() -> Nil {
  let big = gzip.Subfield(id_1: 0x41, id_2: 0x42, data: <<0:size(524_288)>>)
  gzip.encode(<<>>, header: gzip.Header(..empty, extra: [big]))
  |> should.equal(Error(gzip.SubfieldTooLong(length: 65_536)))
}

pub fn encode_rejects_subfield_id_out_of_range_test() -> Nil {
  let bad = gzip.Subfield(id_1: 256, id_2: 0, data: <<>>)
  gzip.encode(<<>>, header: gzip.Header(..empty, extra: [bad]))
  |> should.equal(Error(gzip.SubfieldIdOutOfRange(id_1: 256, id_2: 0)))
}

pub fn decode_multi_member_concatenated_test() -> Nil {
  // RFC 1952 §2.2 explicitly allows a gzip stream to consist of
  // multiple concatenated members (e.g. `cat a.gz b.gz > c.gz`).
  // The decoder must concatenate the per-member payloads.
  let member_a = gzip.encode_without_header(<<"alpha-":utf8>>)
  let member_b = gzip.encode_without_header(<<"bravo-":utf8>>)
  let member_c = gzip.encode_without_header(<<"charlie":utf8>>)
  let combined = bit_array.concat([member_a, member_b, member_c])
  let assert Ok(decoded) = gzip.decode(combined, limits: limit.default())
  decoded.payload
  |> should.equal(<<"alpha-bravo-charlie":utf8>>)
}

pub fn decode_multi_member_via_payload_helper_test() -> Nil {
  let member_a = gzip.encode_without_header(<<"x":utf8>>)
  let member_b = gzip.encode_without_header(<<"y":utf8>>)
  let assert Ok(plain) =
    packkit.decompress(bit_array.concat([member_a, member_b]), with: codec.Gzip)
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
  let member = gzip.encode_without_header(payload)
  let combined = bit_array.concat([member, member, member])
  // Limit allows up to 40 output bytes, so member 1 fits, member
  // 2 pushes the running total to 40, member 3 should overflow.
  let restrictive_limits = limit.Limits(..limit.default(), max_output_bytes: 40)
  case gzip.decode(combined, limits: restrictive_limits) {
    Error(codec.LimitExceeded(limit: "max_output_bytes", actual: _)) -> Nil
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
    gzip.Header(name: None, comment: None, modified_at: None, extra: [
      bgzf_subfield,
    ])
  let payload = <<"bgzf-test-payload":utf8>>

  let assert Ok(bytes) = gzip.encode(payload, header: header)
  let assert Ok(decoded) = gzip.decode(bytes, limits: limit.default())
  decoded.payload
  |> should.equal(payload)
  decoded.header.extra
  |> should.equal([bgzf_subfield])
}

pub fn fextra_roundtrip_multiple_subfields_test() -> Nil {
  let s1 = gzip.Subfield(id_1: 0x42, id_2: 0x43, data: <<0xCA, 0xFE>>)
  let s2 = gzip.Subfield(id_1: 0x52, id_2: 0x72, data: <<"hello":utf8>>)
  let header =
    gzip.Header(name: None, comment: None, modified_at: None, extra: [s1, s2])
  let payload = <<"multi-subfield":utf8>>

  let assert Ok(bytes) = gzip.encode(payload, header: header)
  let assert Ok(decoded) = gzip.decode(bytes, limits: limit.default())
  decoded.payload
  |> should.equal(payload)
  decoded.header.extra
  |> should.equal([s1, s2])
}

pub fn fextra_roundtrip_with_name_and_comment_test() -> Nil {
  // Exercise the encoder path where every optional flag fires.
  let subfield = gzip.Subfield(id_1: 0x41, id_2: 0x70, data: <<>>)
  let header =
    gzip.Header(
      name: Some("data.txt"),
      comment: Some("all fields populated"),
      modified_at: None,
      extra: [subfield],
    )
  let payload = <<"all-fields":utf8>>
  let assert Ok(bytes) = gzip.encode(payload, header: header)
  let assert Ok(decoded) = gzip.decode(bytes, limits: limit.default())
  decoded.payload
  |> should.equal(payload)
  decoded.header.name
  |> should.equal(Some("data.txt"))
  decoded.header.comment
  |> should.equal(Some("all fields populated"))
  decoded.header.extra
  |> should.equal([subfield])
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
  case gzip.decode(header_with_reserved_bit, limits: limit.default()) {
    Error(codec.InvalidData(message: "gzip reserved FLG bits set")) -> Nil
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
  let assert Ok(decoded) = gzip.decode(good, limits: limit.default())
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
  case gzip.decode(bad, limits: limit.default()) {
    Error(codec.InvalidData(message: "gzip header CRC16 mismatch")) -> Nil
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

  let assert Ok(decoded) = gzip.decode(stream, limits: limit.default())
  // UTF-8 string "café" — U+00E9 encodes to bytes C3 A9.
  decoded.header.name
  |> should.equal(Some("café"))
  decoded.payload
  |> should.equal(<<>>)
}
