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

pub fn compressed_metablock_reaches_descriptor_stage_test() -> Nil {
  // `printf 'aaaaaaaaaa' | brotli -c` — brotli chooses a compressed
  // metablock for inputs around 10 bytes.  The decoder now reads the
  // metablock prelude (NBLTYPES_{L,I,D}, NPOSTFIX, NDIRECT, context
  // modes) before erroring at the prefix-code descriptor stage.
  let stream = <<0x1F, 0x09, 0x00, 0xF8, 0x25, 0xC2, 0x82, 0x84, 0x00, 0x00>>
  let expected_feature =
    "brotli prefix-code descriptors, context maps, and command loop (RFC 7932 §3.4–§4)"
  brotli.decode(bytes: stream)
  |> should.equal(Error(error.CodecNotImplemented(feature: expected_feature)))
}

pub fn compressed_metablock_with_small_wbits_reaches_same_stage_test() -> Nil {
  // `printf 'aaaaaaaaaa' | brotli -c --lgwin=10` — the same 10-byte
  // payload encoded with a smaller window.  Because WBITS doesn't
  // change the bit positions of later fields, this also reaches the
  // prefix-code descriptor stage.  Regression coverage for the
  // `triple == 0` branch of `read_wbits`.
  let stream = <<0xA1, 0x48, 0x00, 0xC0, 0x2F, 0x11, 0x16, 0x24, 0x04, 0x00>>
  let expected_feature =
    "brotli prefix-code descriptors, context maps, and command loop (RFC 7932 §3.4–§4)"
  brotli.decode(bytes: stream)
  |> should.equal(Error(error.CodecNotImplemented(feature: expected_feature)))
}
