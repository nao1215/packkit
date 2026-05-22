import gleeunit/should
import packkit/archive
import packkit/error
import packkit/seven_z

pub fn format_marker_test() -> Nil {
  seven_z.format()
  |> archive.format_name
  |> should.equal("7z")
}

pub fn encode_reports_not_implemented_test() -> Nil {
  seven_z.encode(archive: seven_z.new())
  |> should.equal(Error(error.ArchiveNotImplemented(feature: "seven_z.encode")))
}

pub fn decode_reports_not_implemented_test() -> Nil {
  // 7z magic header followed by zeros.
  seven_z.decode(bytes: <<0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C>>)
  |> should.equal(Error(error.ArchiveNotImplemented(feature: "seven_z.decode")))
}
