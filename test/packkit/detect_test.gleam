import gleam/option.{None, Some}
import gleeunit/should
import packkit/archive
import packkit/codec
import packkit/detect
import packkit/error
import packkit/recipe

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

pub fn from_bytes_zstd_skippable_frame_test() -> Nil {
  // zstd skippable frames carry user metadata between real zstd
  // frames; many wrappers (zfs, archive containers) embed them at
  // the very start of a stream.  The detector must recognise the
  // 0x184D2A5_ magic range so those streams still resolve to zstd.
  let lowest = <<0x50, 0x2A, 0x4D, 0x18, 0x00, 0x00, 0x00, 0x00>>
  let highest = <<0x5F, 0x2A, 0x4D, 0x18, 0x00, 0x00, 0x00, 0x00>>
  // 0x4F is one below the range, must not match.
  let below_range = <<0x4F, 0x2A, 0x4D, 0x18, 0x00, 0x00, 0x00, 0x00>>
  let assert Ok(low_info) = detect.from_bytes(lowest)
  low_info |> detect.codec |> should.equal(Some(codec.zstd()))
  let assert Ok(high_info) = detect.from_bytes(highest)
  high_info |> detect.codec |> should.equal(Some(codec.zstd()))
  case detect.from_bytes(below_range) {
    Error(error.DetectUnknownFormat(_)) -> Nil
    _ -> should.fail()
  }
}

pub fn from_bytes_snappy_framed_stream_identifier_test() -> Nil {
  // Snappy framed streams start with chunk_type=0xFF (stream
  // identifier), chunk_length=6 (LE 24-bit), body="sNaPpY".
  let real_snappy = <<
    0xFF, 0x06, 0x00, 0x00, 0x73, 0x4E, 0x61, 0x50, 0x70, 0x59, 0x00,
  >>
  let assert Ok(info) = detect.from_bytes(real_snappy)
  detect.codec(info)
  |> should.equal(Some(codec.snappy()))
}

// -- from_path_or_bytes ----------------------------------------------
//
// The convenience wrapper tries filename detection first and falls
// back to magic-byte detection when the path is uninformative.  These
// tests pin the resolution order so future tweaks to either lookup
// path don't silently change which side wins for each input shape.

pub fn from_path_or_bytes_prefers_filename_match_test() -> Nil {
  // Filename matches a known recipe; bytes are gibberish (would fail
  // magic-byte detection).  The filename hit must win.
  let assert Ok(info) =
    detect.from_path_or_bytes(path: "archive.tar.gz", bytes: <<
      "this is not a gzip stream":utf8,
    >>)
  detect.recipe(info)
  |> should.equal(Some(recipe.tar_gzip()))
}

pub fn from_path_or_bytes_falls_back_to_bytes_test() -> Nil {
  // Path is the conventional "no useful extension" placeholder; the
  // bytes carry a real gzip magic + valid DEFLATE method byte so the
  // fallback resolves to gzip.
  let real_gzip = <<
    0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x03, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  >>
  let assert Ok(info) = detect.from_path_or_bytes(path: "-", bytes: real_gzip)
  detect.codec(info)
  |> should.equal(Some(codec.gzip()))
}

pub fn from_path_or_bytes_surfaces_caller_path_when_both_unknown_test() -> Nil {
  // Both the filename and the bytes are uninformative.  The wrapper
  // must surface the caller-supplied `path` in the `input` field — not
  // the internal `"byte-signature scan"` sentinel, which is opaque to
  // end users and was the behaviour earlier revisions exposed.
  case
    detect.from_path_or_bytes(path: "mystery.bin", bytes: <<
      "definitely not a recognised header":utf8,
    >>)
  {
    Error(error.DetectUnknownFormat(input: "mystery.bin")) -> Nil
    _ -> should.fail()
  }
}
