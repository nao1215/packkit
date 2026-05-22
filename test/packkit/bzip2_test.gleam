import gleeunit/should
import packkit/bzip2
import packkit/codec
import packkit/error

pub fn codec_marker_test() -> Nil {
  bzip2.codec()
  |> codec.name
  |> should.equal("bzip2")
}

pub fn decode_reports_not_implemented_test() -> Nil {
  // bzip2 (BZh) magic header.
  bzip2.decode(bytes: <<0x42, 0x5A, 0x68, 0x39>>)
  |> should.equal(Error(error.CodecNotImplemented(feature: "bzip2.decode")))
}

pub fn encode_reports_not_implemented_test() -> Nil {
  bzip2.encode(bytes: <<>>)
  |> should.equal(Error(error.CodecNotImplemented(feature: "bzip2.encode")))
}
