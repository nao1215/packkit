//// Tests for the non-predefined FSE compression modes
//// (`RLE_Mode` and `FSE_Compressed_Mode`) in the Zstandard sequences
//// section, plus regression coverage for the previously-rejected
//// `Repeat_Mode` path.

import gleeunit/should
import packkit/error
import packkit/zstd

pub fn zstd_rejects_repeat_mode_with_clear_error_test() -> Nil {
  // Repeat_Mode reuses the previous block's FSE table, but the
  // current decoder only carries state within a single block.  Make
  // sure a stream that asks for repeat_mode surfaces a typed
  // `CodecNotImplemented` rather than panicking or returning a
  // generic CodecInvalidData.
  //
  // Forged stream:
  // - magic 28b52ffd
  // - FHD 0x20 (Single_Segment=1, FCS_Flag=00 -> 1 byte FCS, no checksum)
  // - FCS 0x01 (output size = 1 byte)
  // - block header 0x1d 0x00 0x00 (last=1, type=2 compressed, size=3)
  // - block content (3 bytes):
  //   - literals header 0x00 (raw, size_format=0, regen=0)
  //   - sequences count 0x01 (1 sequence)
  //   - modes byte 0x30 (LL=0 predef, OF=3 repeat, ML=0 predef)
  let stream = <<
    0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x01, 0x1D, 0x00, 0x00, 0x00, 0x01, 0x30,
  >>
  case zstd.decode(bytes: stream) {
    Error(error.CodecNotImplemented(feature: _)) -> Nil
    _ -> should.fail()
  }
}

pub fn zstd_rejects_ll_repeat_mode_test() -> Nil {
  // Same as above but with LL in Repeat_Mode.
  let stream = <<
    0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x01, 0x1D, 0x00, 0x00, 0x00, 0x01, 0xC0,
  >>
  case zstd.decode(bytes: stream) {
    Error(error.CodecNotImplemented(feature: _)) -> Nil
    _ -> should.fail()
  }
}

pub fn zstd_rejects_ml_repeat_mode_test() -> Nil {
  // Same as above but with ML in Repeat_Mode.
  let stream = <<
    0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x01, 0x1D, 0x00, 0x00, 0x00, 0x01, 0x0C,
  >>
  case zstd.decode(bytes: stream) {
    Error(error.CodecNotImplemented(feature: _)) -> Nil
    _ -> should.fail()
  }
}
