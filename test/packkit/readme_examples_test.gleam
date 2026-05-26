//// Every code block in README.md ships as a test here so that
//// the example never silently rots against the public API.  If you
//// edit one, edit the README too — and vice versa.

import gleam/list
import gleam/option.{type Option, Some}
import gleeunit/should
import packkit
import packkit/ar
import packkit/archive
import packkit/checksum
import packkit/codec
import packkit/cpio
import packkit/detect
import packkit/entry
import packkit/error
import packkit/gzip
import packkit/level
import packkit/limit
import packkit/recipe
import packkit/seven_z
import packkit/stream
import packkit/tar
import packkit/zip

// -- Quick start ----------------------------------------------------------

fn build_and_read_tar_gz() -> Int {
  let archive_value =
    tar.new()
    |> tar.add_file(path: "hello.txt", body: <<"hello":utf8>>)
    |> tar.add_file(path: "world.txt", body: <<"world":utf8>>)

  let assert Ok(bytes) =
    packkit.pack(archive_value: archive_value, using: recipe.tar_gzip())

  let assert Ok(decoded) =
    packkit.unpack(bytes: bytes, using: recipe.tar_gzip())

  archive.entry_count(decoded)
}

pub fn readme_quick_start_test() -> Nil {
  build_and_read_tar_gz()
  |> should.equal(2)
}

// -- Single byte stream ---------------------------------------------------

fn gzip_roundtrip(payload: BitArray) -> BitArray {
  let assert Ok(compressed) =
    packkit.compress(bytes: payload, with: codec.gzip())
  let assert Ok(restored) =
    packkit.decompress(bytes: compressed, with: codec.gzip())
  restored
}

fn zstd_roundtrip(payload: BitArray) -> BitArray {
  let assert Ok(stream_bytes) =
    packkit.compress(bytes: payload, with: codec.zstd())
  let assert Ok(plain) =
    packkit.decompress(bytes: stream_bytes, with: codec.zstd())
  plain
}

fn bzip2_roundtrip(payload: BitArray) -> BitArray {
  let assert Ok(stream_bytes) =
    packkit.compress(bytes: payload, with: codec.bzip2())
  let assert Ok(plain) =
    packkit.decompress(bytes: stream_bytes, with: codec.bzip2())
  plain
}

fn brotli_roundtrip(payload: BitArray) -> BitArray {
  let assert Ok(stream_bytes) =
    packkit.compress(bytes: payload, with: codec.brotli())
  let assert Ok(plain) =
    packkit.decompress(bytes: stream_bytes, with: codec.brotli())
  plain
}

pub fn readme_codec_facade_test() -> Nil {
  let payload = <<"packkit readme example payload":utf8>>
  gzip_roundtrip(payload) |> should.equal(payload)
  zstd_roundtrip(payload) |> should.equal(payload)
  bzip2_roundtrip(payload) |> should.equal(payload)
  brotli_roundtrip(payload) |> should.equal(payload)
}

// -- Building archives ----------------------------------------------------

fn build_tar_with_metadata() -> BitArray {
  let archive_value =
    tar.new()
    |> tar.add_directory(path: "etc")
    |> tar.add_file(path: "etc/motd", body: <<"welcome":utf8>>)
    |> tar.add_symlink(path: "etc/banner", target: "motd")
    |> archive.add(
      entry: entry.file(path: "bin/run", body: <<"#!/bin/sh\n":utf8>>)
      |> entry.with_mode(mode: 0o755)
      |> entry.with_owner(user_id: 1000, group_id: 1000)
      |> entry.with_modified_at(unix_seconds: 1_700_000_000),
    )

  let assert Ok(bytes) =
    packkit.write(archive_value: archive_value, format: tar.format())
  bytes
}

pub fn readme_tar_with_metadata_test() -> Nil {
  // The README's example must actually round-trip; check that the
  // metadata survives encode + decode.
  let bytes = build_tar_with_metadata()
  let assert Ok(decoded) = packkit.read(bytes: bytes, format: tar.format())

  let assert Ok(run) = archive.entry_by_path(decoded, path: "bin/run")
  entry.mode(entry.metadata(run))
  |> should.equal(0o755)
  entry.user_id(entry.metadata(run))
  |> should.equal(1000)
  entry.modified_at_unix(entry.metadata(run))
  |> should.equal(1_700_000_000)

  let assert Ok(banner) = archive.entry_by_path(decoded, path: "etc/banner")
  entry.is_symlink(banner)
  |> should.equal(True)
}

fn rejects_traversal() -> Result(archive.Archive, entry.EntryError) {
  tar.add_file_checked(archive: tar.new(), path: "../etc/passwd", body: <<
    "x":utf8,
  >>)
}

pub fn readme_traversal_rejection_test() -> Nil {
  rejects_traversal()
  |> should.equal(Error(entry.PathTraversal("../etc/passwd")))
}

fn build_cpio() -> BitArray {
  let archive_value =
    cpio.new()
    |> archive.add_file(path: "lib/libfoo.so", body: <<"…":utf8>>)
    |> archive.add_file(path: "lib/libbar.so", body: <<"…":utf8>>)
  let assert Ok(bytes) =
    packkit.write(archive_value: archive_value, format: cpio.format())
  bytes
}

fn build_ar() -> BitArray {
  let archive_value =
    ar.new()
    |> archive.add_file(path: "main.o", body: <<"obj":utf8>>)
    |> archive.add_file(path: "debian-binary", body: <<"2.0\n":utf8>>)
  let assert Ok(bytes) =
    packkit.write(archive_value: archive_value, format: ar.format())
  bytes
}

fn build_seven_z() -> BitArray {
  let archive_value =
    seven_z.new()
    |> archive.add_file(path: "doc/spec.txt", body: <<"hello 7z":utf8>>)
    |> archive.add_file(path: "doc/notes.txt", body: <<"more":utf8>>)
  let assert Ok(bytes) =
    packkit.write(archive_value: archive_value, format: seven_z.format())
  bytes
}

pub fn readme_cpio_ar_seven_z_test() -> Nil {
  let cpio_bytes = build_cpio()
  let assert Ok(cpio_decoded) =
    packkit.read(bytes: cpio_bytes, format: cpio.format())
  archive.entry_count(cpio_decoded)
  |> should.equal(2)

  let ar_bytes = build_ar()
  let assert Ok(ar_decoded) = packkit.read(bytes: ar_bytes, format: ar.format())
  archive.entry_count(ar_decoded)
  |> should.equal(2)

  let seven_z_bytes = build_seven_z()
  let assert Ok(seven_z_decoded) =
    packkit.read(bytes: seven_z_bytes, format: seven_z.format())
  archive.entry_count(seven_z_decoded)
  |> should.equal(2)
}

// -- Recipe composition ---------------------------------------------------

fn cpio_lz4_then_zstd() -> recipe.Recipe {
  recipe.archive_with(format: archive.cpio_newc(), wrapped_by: codec.lz4())
  |> recipe.wrap(with: codec.zstd())
}

pub fn readme_recipe_composition_test() -> Nil {
  cpio_lz4_then_zstd()
  |> recipe.description
  |> should.equal("cpio-newc.lz4.zstd")
}

// -- Detection ------------------------------------------------------------

fn recipe_for_filename(path: String) -> Option(recipe.Recipe) {
  let assert Ok(info) = packkit.detect_filename(path)
  detect.recipe(info)
}

pub fn readme_detect_filename_test() -> Nil {
  recipe_for_filename("backup-2026-05-22.tar.gz")
  |> should.equal(Some(recipe.tar_gzip()))

  recipe_for_filename("logs.tar.zst")
  |> should.equal(Some(recipe.tar_zstd()))
}

fn pick_codec(path: String, leading_bytes: BitArray) -> Option(codec.Codec) {
  detect.from_path_or_bytes(path: path, bytes: leading_bytes)
  |> option.from_result
  |> option.then(detect.codec)
}

pub fn readme_detect_path_or_bytes_test() -> Nil {
  // Filename hits first when it has a known compound extension.
  pick_codec("download.tar.gz", <<>>)
  |> should.equal(Some(codec.gzip()))

  // When the path is opaque, magic-byte detection takes over.
  let payload = <<"hello":utf8>>
  let assert Ok(gz) = packkit.compress(bytes: payload, with: codec.gzip())
  pick_codec("blob.bin", gz)
  |> should.equal(Some(codec.gzip()))
}

// -- Inspecting an archive ------------------------------------------------

fn extract_one_file(bytes: BitArray) -> Result(BitArray, Nil) {
  let assert Ok(decoded) =
    packkit.unpack(bytes: bytes, using: recipe.tar_gzip())
  case archive.entry_by_path(decoded, path: "hello.txt") {
    Ok(found) -> Ok(entry.body(found))
    Error(_) -> Error(Nil)
  }
}

fn list_files(bytes: BitArray) -> List(String) {
  let assert Ok(decoded) =
    packkit.unpack(bytes: bytes, using: recipe.tar_gzip())
  archive.entries(decoded)
  |> list.filter(entry.is_file)
  |> list.map(fn(e) { entry.to_string(entry.path(e)) })
}

pub fn readme_inspect_archive_test() -> Nil {
  let archive_value =
    tar.new()
    |> tar.add_file(path: "hello.txt", body: <<"hi from README":utf8>>)
    |> tar.add_file(path: "world.txt", body: <<"world":utf8>>)
  let assert Ok(bytes) =
    packkit.pack(archive_value: archive_value, using: recipe.tar_gzip())

  extract_one_file(bytes)
  |> should.equal(Ok(<<"hi from README":utf8>>))

  list_files(bytes)
  |> should.equal(["hello.txt", "world.txt"])
}

// -- ZIP per-entry methods ------------------------------------------------

fn write_deflated_zip() -> BitArray {
  let archive_value =
    zip.new()
    |> archive.add_file(path: "report.csv", body: <<"a,b,c\n1,2,3\n":utf8>>)
    |> archive.add_file(path: "notes.txt", body: <<"keep me":utf8>>)
  let assert Ok(bytes) =
    zip.encode_with_method(
      archive: archive_value,
      method: zip.deflate(level: level.default()),
    )
  bytes
}

fn write_zstd_zip() -> BitArray {
  let archive_value =
    zip.new()
    |> archive.add_file(path: "blob.bin", body: <<"…":utf8>>)
  let assert Ok(bytes) =
    zip.encode_with_method(archive: archive_value, method: zip.zstd())
  bytes
}

fn read_zip(bytes: BitArray) -> Int {
  let assert Ok(decoded) = packkit.unpack(bytes: bytes, using: recipe.zip())
  archive.entry_count(decoded)
}

pub fn readme_zip_methods_test() -> Nil {
  read_zip(write_deflated_zip())
  |> should.equal(2)
  read_zip(write_zstd_zip())
  |> should.equal(1)
}

// -- gzip header round-trip ----------------------------------------------

fn gzip_with_header_metadata(
  payload: BitArray,
) -> #(BitArray, Result(gzip.Decoded, error.CodecError)) {
  let header =
    gzip.default_header()
    |> gzip.with_name(name: "report.csv")
    |> gzip.with_comment(comment: "generated by packkit")
    |> gzip.with_modified_at(unix_seconds: 1_700_000_000)

  let assert Ok(bytes) = gzip.encode_with_header(bytes: payload, header: header)
  #(bytes, gzip.decode(bytes: bytes))
}

pub fn readme_gzip_header_roundtrip_test() -> Nil {
  let payload = <<"a,b,c\n1,2,3\n":utf8>>
  let #(_bytes, decoded_result) = gzip_with_header_metadata(payload)
  let assert Ok(decoded) = decoded_result
  gzip.name(decoded.header)
  |> should.equal(Some("report.csv"))
  gzip.comment(decoded.header)
  |> should.equal(Some("generated by packkit"))
  gzip.modified_at_unix(decoded.header)
  |> should.equal(Some(1_700_000_000))
}

// -- Streaming chunks -----------------------------------------------------

fn streamed_gzip_roundtrip(payload: BitArray) -> BitArray {
  let assert Ok(stream_bytes) =
    packkit.compress(bytes: payload, with: codec.gzip())

  let chunks = [stream_bytes, <<>>]

  let assert Ok(plain) =
    stream.decode_chunks(decoder: stream.new_gzip_decoder(), chunks: chunks)
  plain
}

pub fn readme_stream_roundtrip_test() -> Nil {
  let payload = <<"stream the bytes in two halves":utf8>>
  streamed_gzip_roundtrip(payload)
  |> should.equal(payload)
}

// -- Resource limits ------------------------------------------------------

fn refuse_oversized_gzip(stream_bytes: BitArray) -> Bool {
  let tight = limit.default() |> limit.with_max_input_bytes(bytes: 4)
  case
    packkit.decompress_with_limits(
      bytes: stream_bytes,
      with: codec.gzip(),
      limits: tight,
    )
  {
    Error(error.CodecLimitExceeded(limit: "max_input_bytes", actual: _)) -> True
    _ -> False
  }
}

pub fn readme_resource_limits_test() -> Nil {
  let payload = <<"larger than 4 bytes":utf8>>
  let assert Ok(stream_bytes) =
    packkit.compress(bytes: payload, with: codec.gzip())
  refuse_oversized_gzip(stream_bytes)
  |> should.equal(True)
}

// -- Checksums ------------------------------------------------------------

fn checksums() -> #(Int, Int, BitArray) {
  let payload = <<"packkit":utf8>>
  #(
    checksum.adler32(data: payload),
    checksum.crc32(data: payload),
    checksum.sha256(data: payload),
  )
}

pub fn readme_checksums_test() -> Nil {
  let #(adler, crc, sha) = checksums()
  // Adler-32 of "packkit" computed by walking the spec:
  //   s1 ends at 744, s2 at 2943, result = (s2 << 16) | s1.
  adler
  |> should.equal(192_873_192)
  // CRC-32 over a non-empty payload must be non-zero and fit in 32 bits.
  case crc > 0 && crc <= 0xFFFFFFFF {
    True -> Nil
    False -> should.fail()
  }
  // SHA-256 is 32 bytes by construction.
  case sha {
    <<_:bits-size(256)>> -> Nil
    _ -> should.fail()
  }
}

// -- Error handling -------------------------------------------------------

fn refuses_format_mismatch() -> String {
  let zip_archive_value =
    zip.new()
    |> archive.add(entry: entry.file(path: "x", body: <<"x":utf8>>))

  case
    packkit.pack(archive_value: zip_archive_value, using: recipe.tar_gzip())
  {
    Error(err) -> error.format_archive_error(err)
    Ok(_) -> "ok"
  }
}

pub fn readme_error_format_test() -> Nil {
  refuses_format_mismatch()
  |> should.equal(
    "archive: format mismatch (archive was built as \"zip\" but \"tar\" was requested)",
  )
}
