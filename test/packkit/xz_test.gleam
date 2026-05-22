import gleeunit/should
import packkit/codec
import packkit/error
import packkit/xz

pub fn codec_marker_test() -> Nil {
  xz.codec()
  |> codec.name
  |> should.equal("xz")
}

pub fn decode_reports_not_implemented_test() -> Nil {
  // xz magic header.
  xz.decode(bytes: <<0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00>>)
  |> should.equal(Error(error.CodecNotImplemented(feature: "xz.decode")))
}

pub fn encode_reports_not_implemented_test() -> Nil {
  xz.encode(bytes: <<>>)
  |> should.equal(Error(error.CodecNotImplemented(feature: "xz.encode")))
}
