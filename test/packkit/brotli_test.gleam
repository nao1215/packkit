import gleeunit/should
import packkit/brotli
import packkit/codec
import packkit/error

pub fn codec_marker_test() -> Nil {
  brotli.codec()
  |> codec.name
  |> should.equal("brotli")
}

pub fn decode_reports_not_implemented_test() -> Nil {
  brotli.decode(bytes: <<0xCE, 0xB2, 0xCF, 0x81>>)
  |> should.equal(Error(error.CodecNotImplemented(feature: "brotli.decode")))
}

pub fn encode_reports_not_implemented_test() -> Nil {
  brotli.encode(bytes: <<>>)
  |> should.equal(Error(error.CodecNotImplemented(feature: "brotli.encode")))
}
