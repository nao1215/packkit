import gleeunit/should
import packkit/brotli
import packkit/codec
import packkit/error

pub fn codec_marker_test() -> Nil {
  brotli.codec()
  |> codec.name
  |> should.equal("brotli")
}

pub fn encode_reports_not_implemented_test() -> Nil {
  brotli.encode(bytes: <<>>)
  |> should.equal(Error(error.CodecNotImplemented(feature: "brotli.encode")))
}

pub fn decode_empty_stream_test() -> Nil {
  // `printf '' | brotli -c` — canonical empty stream byte.
  brotli.decode(bytes: <<0x3F>>)
  |> should.equal(Ok(<<>>))
}

pub fn decode_hi_uncompressed_metablock_test() -> Nil {
  // `printf 'hi' | brotli -c` — brotli emits a single ISUNCOMPRESSED
  // metablock for tiny inputs that it can't compress profitably.
  brotli.decode(bytes: <<0x8F, 0x00, 0x80, 0x68, 0x69, 0x03>>)
  |> should.equal(Ok(<<"hi":utf8>>))
}

pub fn decode_hello_uncompressed_metablock_test() -> Nil {
  // `printf 'hello' | brotli -c`.
  brotli.decode(bytes: <<0x0F, 0x02, 0x80, 0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x03>>)
  |> should.equal(Ok(<<"hello":utf8>>))
}

pub fn decode_abc_uncompressed_metablock_test() -> Nil {
  // `printf 'abc' | brotli -c`.
  brotli.decode(bytes: <<0x0F, 0x01, 0x80, 0x61, 0x62, 0x63, 0x03>>)
  |> should.equal(Ok(<<"abc":utf8>>))
}

pub fn decode_hi_with_wbits_18_test() -> Nil {
  // `printf 'hi' | brotli -c --lgwin=18` — exercises a non-default
  // WBITS encoding that used to fall through the `triple < 4` branch
  // of `read_wbits`.  Decoder treats the metablock as uncompressed
  // regardless of WBITS value, so this is also a smoke test that the
  // fixed prefix consumes the right number of bits.
  brotli.decode(bytes: <<0x83, 0x00, 0x80, 0x68, 0x69, 0x03>>)
  |> should.equal(Ok(<<"hi":utf8>>))
}

pub fn decode_compressed_10a_test() -> Nil {
  // `printf 'aaaaaaaaaa' | brotli -c` — end-to-end round-trip of a
  // compressed metablock using simple-form prefix codes plus a single
  // in-window LZ77 copy (1 literal 'a' + 9-byte copy at distance 1).
  let stream = <<0x1F, 0x09, 0x00, 0xF8, 0x25, 0xC2, 0x82, 0x84, 0x00, 0x00>>
  brotli.decode(bytes: stream)
  |> should.equal(Ok(<<"aaaaaaaaaa":utf8>>))
}

pub fn decode_compressed_10a_with_small_wbits_test() -> Nil {
  // `printf 'aaaaaaaaaa' | brotli -c --lgwin=10` — same payload, but
  // the WBITS prefix exercises the `triple == 0` branch of
  // `read_wbits` (fixed earlier this session) and the distance
  // decoder's NPOSTFIX/NDIRECT-derived parameters.
  let stream = <<0xA1, 0x48, 0x00, 0xC0, 0x2F, 0x11, 0x16, 0x24, 0x04, 0x00>>
  brotli.decode(bytes: stream)
  |> should.equal(Ok(<<"aaaaaaaaaa":utf8>>))
}

pub fn decode_compressed_16a_test() -> Nil {
  // `printf 'aaaaaaaaaaaaaaaa' | brotli -c` (16 `a`s).
  let stream = <<0x1F, 0x0F, 0x00, 0xF8, 0x25, 0xC2, 0x22, 0x8C, 0x00, 0x00>>
  brotli.decode(bytes: stream)
  |> should.equal(Ok(<<"aaaaaaaaaaaaaaaa":utf8>>))
}

pub fn decode_compressed_time_of_the_day_test() -> Nil {
  // `printf 'time of the day' | brotli -c` — exercises the static
  // dictionary: first command resolves to `time` + " of the " suffix
  // via transform idx 8 (IDENTITY + suffix), then a second command
  // adds the literal "day".
  let stream = <<
    0x1F, 0x0E, 0x00, 0xF8, 0xA5, 0xC2, 0xF2, 0x52, 0x10, 0x49, 0x84, 0x29, 0x80,
    0x56, 0xA2, 0x7E, 0x8A, 0x20, 0x01,
  >>
  brotli.decode(bytes: stream)
  |> should.equal(Ok(<<"time of the day":utf8>>))
}

pub fn decode_compressed_hello_world_test() -> Nil {
  // `printf 'Hello, World! This is brotli testing.' | brotli -c` —
  // exercises complex-form prefix codes plus multiple static-dict
  // refs (UPPERCASE_FIRST transforms on "world" and "this", etc.).
  let stream = <<
    0x1F, 0x24, 0x00, 0xE0, 0xC5, 0x6D, 0x6C, 0x5D, 0x1D, 0xA7, 0x77, 0xFB, 0xD1,
    0x09, 0x04, 0x41, 0xEA, 0x41, 0x14, 0xA9, 0xE5, 0x16, 0xC5, 0xD2, 0x91, 0x58,
    0x5D, 0x3B, 0x5A, 0xB2, 0x77, 0xE2, 0xD7, 0xC1, 0xD6, 0x02,
  >>
  brotli.decode(bytes: stream)
  |> should.equal(Ok(<<"Hello, World! This is brotli testing.":utf8>>))
}

pub fn decode_compressed_20a_test() -> Nil {
  // `printf 'timetimetimetimetime' | brotli -c` — longer run that
  // uses the same literal-then-copy pattern as `timetimetime`.
  let stream = <<
    0x1F, 0x13, 0x00, 0xF8, 0xA5, 0xCB, 0xD2, 0xDA, 0xE8, 0x84, 0x18, 0x01, 0x80,
    0x1B,
  >>
  brotli.decode(bytes: stream)
  |> should.equal(Ok(<<"timetimetimetimetime":utf8>>))
}
