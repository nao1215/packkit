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

pub fn decode_non_empty_pending_test() -> Nil {
  // `printf 'hi' | brotli -c` — needs the full RFC 7932 decoder.
  case brotli.decode(bytes: <<0x8F, 0x00, 0x80, 0x68, 0x69, 0x03>>) {
    Error(error.CodecNotImplemented(feature: _)) -> Nil
    other -> {
      other
      |> should.equal(
        Error(error.CodecNotImplemented(
          feature: "brotli non-empty streams (RFC 7932 metablocks + static dictionary)",
        )),
      )
    }
  }
}
