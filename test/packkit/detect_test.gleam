import gleeunit/should
import packkit.{Archived, Compressed, Recipe}
import packkit/archive
import packkit/codec

pub fn detect_filename_recognizes_compound_tar_xz_test() -> Nil {
  packkit.detect_filename("release.tar.xz")
  |> should.equal(Ok(Archived(Recipe(archive.Tar, [codec.Xz]))))
}

pub fn detect_filename_ignores_case_test() -> Nil {
  packkit.detect_filename("BACKUP.TGZ")
  |> should.equal(Ok(Archived(Recipe(archive.Tar, [codec.Gzip]))))
}

pub fn detect_filename_unknown_extension_test() -> Nil {
  packkit.detect_filename("notes.qq")
  |> should.equal(Error(Nil))
}

pub fn detect_filename_archive_only_has_no_codec_test() -> Nil {
  packkit.detect_filename("archive.tar")
  |> should.equal(Ok(Archived(Recipe(archive.Tar, []))))
}

pub fn detect_filename_single_codec_test() -> Nil {
  packkit.detect_filename("log.zst")
  |> should.equal(Ok(Compressed(codec.Zstd)))
}

pub fn detect_bytes_gzip_requires_deflate_method_byte_test() -> Nil {
  // RFC 1952 reserves CM values other than 8, so the byte-detection
  // path must require the third byte to be 0x08 instead of accepting
  // any `1F 8B _` prefix.
  packkit.detect_bytes(<<0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00>>)
  |> should.equal(Ok(Compressed(codec.Gzip)))
  packkit.detect_bytes(<<0x1F, 0x8B, 0xFF, 0x00, 0x00, 0x00>>)
  |> should.equal(Error(Nil))
}

pub fn detect_bytes_zlib_requires_check_bits_test() -> Nil {
  // A bare `0x78 _` prefix would match any text that starts with `x`,
  // so the signature requires CM == 8, CINFO <= 7 and the FCHECK
  // mod-31 invariant.
  packkit.detect_bytes(<<0x78, 0x9C, 0xCB, 0x00>>)
  |> should.equal(Ok(Compressed(codec.Zlib)))
  // CMF passes but `(0x78 * 256 + 0x21) % 31 = 1`.
  packkit.detect_bytes(<<0x78, 0x21, 0x42>>)
  |> should.equal(Error(Nil))
  // CINFO = 8 is a 64 KiB window, outside zlib's range.
  packkit.detect_bytes(<<0x88, 0x9C, 0x42>>)
  |> should.equal(Error(Nil))
}

pub fn detect_bytes_bzip2_requires_block_size_digit_test() -> Nil {
  packkit.detect_bytes(<<0x42, 0x5A, 0x68, 0x39, 0x00>>)
  |> should.equal(Ok(Compressed(codec.Bzip2)))
  packkit.detect_bytes(<<0x42, 0x5A, 0x68, 0x00, 0x00>>)
  |> should.equal(Error(Nil))
}

pub fn detect_bytes_zstd_skippable_frame_test() -> Nil {
  // zstd skippable frames (magic 0x184D2A50 to 0x184D2A5F) can start a
  // stream, so they must resolve to zstd too.
  packkit.detect_bytes(<<0x50, 0x2A, 0x4D, 0x18, 0x00, 0x00, 0x00, 0x00>>)
  |> should.equal(Ok(Compressed(codec.Zstd)))
  packkit.detect_bytes(<<0x5F, 0x2A, 0x4D, 0x18, 0x00, 0x00, 0x00, 0x00>>)
  |> should.equal(Ok(Compressed(codec.Zstd)))
  packkit.detect_bytes(<<0x4F, 0x2A, 0x4D, 0x18, 0x00, 0x00, 0x00, 0x00>>)
  |> should.equal(Error(Nil))
}

pub fn detect_bytes_snappy_framed_stream_identifier_test() -> Nil {
  packkit.detect_bytes(<<
    0xFF, 0x06, 0x00, 0x00, 0x73, 0x4E, 0x61, 0x50, 0x70, 0x59, 0x00,
  >>)
  |> should.equal(Ok(Compressed(codec.Snappy)))
}

pub fn detect_bytes_ustar_magic_test() -> Nil {
  let header = <<0:size(2056), "ustar":utf8, 0:size(1960)>>
  packkit.detect_bytes(header)
  |> should.equal(Ok(Archived(Recipe(archive.Tar, []))))
}

pub fn detect_prefers_filename_match_test() -> Nil {
  packkit.detect(path: "archive.tar.gz", bytes: <<"not gzip":utf8>>)
  |> should.equal(Ok(Archived(Recipe(archive.Tar, [codec.Gzip]))))
}

pub fn detect_falls_back_to_bytes_test() -> Nil {
  packkit.detect(path: "-", bytes: <<0x1F, 0x8B, 0x08, 0x00>>)
  |> should.equal(Ok(Compressed(codec.Gzip)))
}

pub fn detect_unknown_path_and_bytes_test() -> Nil {
  packkit.detect(path: "mystery.bin", bytes: <<"plain text":utf8>>)
  |> should.equal(Error(Nil))
}
