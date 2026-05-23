import gleam/option.{None, Some}
import gleeunit/should
import packkit/archive
import packkit/codec
import packkit/detect
import packkit/error

pub fn from_filename_recognizes_compound_tar_xz_test() -> Nil {
  let assert Ok(info) = detect.from_filename("release.tar.xz")
  detect.codec(info)
  |> should.equal(Some(codec.xz()))
}

pub fn from_filename_unknown_extension_is_typed_error_test() -> Nil {
  case detect.from_filename("notes.qq") {
    Error(error.DetectUnknownFormat(_)) -> Nil
    _ -> should.fail()
  }
}

pub fn from_bytes_gzip_requires_deflate_method_byte_test() -> Nil {
  // RFC 1952 reserves CM values other than 8, so the byte-detection
  // path must require the third byte to be 0x08 instead of accepting
  // any `1F 8B _` prefix.
  let real_gzip = <<0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00>>
  let bogus = <<0x1F, 0x8B, 0xFF, 0x00, 0x00, 0x00>>
  case detect.from_bytes(real_gzip) {
    Ok(info) ->
      detect.codec(info)
      |> should.equal(Some(codec.gzip()))
    _ -> should.fail()
  }
  case detect.from_bytes(bogus) {
    Error(error.DetectUnknownFormat(_)) -> Nil
    _ -> should.fail()
  }
}

pub fn from_bytes_zlib_requires_check_bits_test() -> Nil {
  // The old heuristic accepted any `0x78 _` prefix, which false-
  // positived on any UTF-8 stream that started with `x`.  The new
  // signature requires CMF.CM == 8, CINFO <= 7, and the FCHECK mod-31
  // invariant.  Bytes that violate either condition no longer pass.
  let real_zlib = <<0x78, 0x9C, 0xCB, 0x00>>
  // `0x78, 0x21` — CMF passes (`CM=8, CINFO=7`) but
  // `(0x78*256 + 0x21) % 31 = 1`, so the header check rejects it.
  let bad_fcheck = <<0x78, 0x21, 0x42>>
  // CINFO=8 (window=16 bits) is out of zlib's legal range.
  let bad_cinfo = <<0x88, 0x9C, 0x42>>
  case detect.from_bytes(real_zlib) {
    Ok(info) ->
      detect.codec(info)
      |> should.equal(Some(codec.zlib()))
    _ -> should.fail()
  }
  case detect.from_bytes(bad_fcheck) {
    Error(error.DetectUnknownFormat(_)) -> Nil
    _ -> should.fail()
  }
  case detect.from_bytes(bad_cinfo) {
    Error(error.DetectUnknownFormat(_)) -> Nil
    _ -> should.fail()
  }
}

pub fn from_bytes_bzip2_requires_block_size_digit_test() -> Nil {
  // The old heuristic accepted any `BZh _` prefix.  bzip2 streams
  // always carry an ASCII digit '1'..'9' as the block-size byte.
  let real_bzip2 = <<0x42, 0x5A, 0x68, 0x39, 0x00>>
  let bogus = <<0x42, 0x5A, 0x68, 0x00, 0x00>>
  case detect.from_bytes(real_bzip2) {
    Ok(info) ->
      detect.codec(info)
      |> should.equal(Some(codec.bzip2()))
    _ -> should.fail()
  }
  case detect.from_bytes(bogus) {
    Error(error.DetectUnknownFormat(_)) -> Nil
    _ -> should.fail()
  }
}

pub fn from_filename_archive_only_has_no_outer_codec_test() -> Nil {
  let assert Ok(info) = detect.from_filename("archive.tar")
  detect.archive(info)
  |> should.equal(Some(archive.tar()))
  detect.codec(info)
  |> should.equal(None)
}
