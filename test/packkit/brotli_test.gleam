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

pub fn compressed_metablock_reaches_command_loop_test() -> Nil {
  // `printf 'aaaaaaaaaa' | brotli -c` — brotli chooses a compressed
  // metablock for inputs around 10 bytes.  The decoder now parses the
  // metablock prelude (NBLTYPES, NPOSTFIX, NDIRECT, context modes),
  // the NTREES counts, and three simple-form prefix-code descriptors
  // (literal, insert-and-copy, distance) before erroring at the
  // command-loop stage.  This proves the full header pipeline lines
  // up bit-for-bit with brotli's encoder output.
  let stream = <<0x1F, 0x09, 0x00, 0xF8, 0x25, 0xC2, 0x82, 0x84, 0x00, 0x00>>
  let expected_feature =
    "brotli command loop (insert-and-copy + sliding window, RFC 7932 §4)"
  brotli.decode(bytes: stream)
  |> should.equal(Error(error.CodecNotImplemented(feature: expected_feature)))
}

pub fn compressed_metablock_with_small_wbits_reaches_command_loop_test() -> Nil {
  // `printf 'aaaaaaaaaa' | brotli -c --lgwin=10` — the same 10-byte
  // payload encoded with a smaller window.  Because WBITS doesn't
  // change the bit positions of later fields, this also reaches the
  // command-loop stage.  Regression coverage for the `triple == 0`
  // branch of `read_wbits` and for simple-form prefix-code parsing
  // with a small (NDIRECT-derived) distance alphabet.
  let stream = <<0xA1, 0x48, 0x00, 0xC0, 0x2F, 0x11, 0x16, 0x24, 0x04, 0x00>>
  let expected_feature =
    "brotli command loop (insert-and-copy + sliding window, RFC 7932 §4)"
  brotli.decode(bytes: stream)
  |> should.equal(Error(error.CodecNotImplemented(feature: expected_feature)))
}

pub fn compressed_metablock_complex_form_reaches_command_loop_test() -> Nil {
  // `printf 'Hello, World! This is brotli testing.' | brotli -c` —
  // text input that triggers complex-form prefix codes (mixed-
  // alphabet literals encoded via the 18-symbol code-length code
  // and 16/17 run-length symbols, RFC 7932 §3.5).  Successful parse
  // through to the command-loop stub is the strongest evidence
  // that the complex-form pipeline reproduces brotli's output.
  let stream = <<
    0x1F, 0x24, 0x00, 0xE0, 0xC5, 0x6D, 0x6C, 0x5D, 0x1D, 0xA7, 0x77, 0xFB, 0xD1,
    0x09, 0x04, 0x41, 0xEA, 0x41, 0x14, 0xA9, 0xE5, 0x16, 0xC5, 0xD2, 0x91, 0x58,
    0x5D, 0x3B, 0x5A, 0xB2, 0x77, 0xE2, 0xD7, 0xC1, 0xD6, 0x02,
  >>
  let expected_feature =
    "brotli command loop (insert-and-copy + sliding window, RFC 7932 §4)"
  brotli.decode(bytes: stream)
  |> should.equal(Error(error.CodecNotImplemented(feature: expected_feature)))
}

pub fn compressed_metablock_16a_reaches_command_loop_test() -> Nil {
  // `printf 'aaaaaaaaaaaaaaaa' | brotli -c` (16 `a`s).  brotli's
  // encoder still uses simple-form prefix codes for this length, so
  // the literal/insert-and-copy/distance descriptors parse cleanly
  // and we reach the same command-loop stage as the 10-byte fixture.
  let stream = <<0x1F, 0x0F, 0x00, 0xF8, 0x25, 0xC2, 0x22, 0x8C, 0x00, 0x00>>
  let expected_feature =
    "brotli command loop (insert-and-copy + sliding window, RFC 7932 §4)"
  brotli.decode(bytes: stream)
  |> should.equal(Error(error.CodecNotImplemented(feature: expected_feature)))
}
