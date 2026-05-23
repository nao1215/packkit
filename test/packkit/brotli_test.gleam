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
