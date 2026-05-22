import gleeunit/should
import packkit/codec
import packkit/error
import packkit/zstd

pub fn codec_marker_test() -> Nil {
  zstd.codec()
  |> codec.name
  |> should.equal("zstd")
}

pub fn decode_reports_not_implemented_test() -> Nil {
  zstd.decode(bytes: <<0x28, 0xB5, 0x2F, 0xFD>>)
  |> should.equal(Error(error.CodecNotImplemented(feature: "zstd.decode")))
}

pub fn encode_reports_not_implemented_test() -> Nil {
  zstd.encode(bytes: <<>>)
  |> should.equal(Error(error.CodecNotImplemented(feature: "zstd.encode")))
}
