import gleam/bit_array
import gleam/option.{Some}
import gleeunit
import gleeunit/should
import packkit
import packkit/archive
import packkit/bzip2
import packkit/codec
import packkit/detect
import packkit/entry
import packkit/error
import packkit/level
import packkit/recipe
import packkit/tar
import packkit/zip

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn package_version_test() -> Nil {
  packkit.package_version()
  |> should.equal("0.1.0")
}

pub fn entry_rejects_parent_traversal_test() -> Nil {
  entry.file_checked(path: "../etc/passwd", body: <<"x":utf8>>)
  |> should.equal(Error(entry.PathTraversal("../etc/passwd")))
}

pub fn entry_accepts_safe_nested_path_test() -> Nil {
  let assert Ok(file) =
    entry.file_checked(path: "doc/reference/spec.md", body: <<"ok":utf8>>)

  entry.kind(file)
  |> should.equal("file")

  file
  |> entry.path
  |> entry.depth
  |> should.equal(3)
}

pub fn tar_gzip_recipe_exposes_archive_and_outer_codec_test() -> Nil {
  let plan = recipe.tar_gzip()

  recipe.archive_format(plan)
  |> should.equal(Some(archive.tar()))

  recipe.outermost_codec(plan)
  |> should.equal(Some(codec.gzip()))

  recipe.description(plan)
  |> should.equal("tar.gzip")
}

pub fn filename_detection_recognizes_tar_gzip_test() -> Nil {
  let assert Ok(info) = detect.from_filename("backup-2026-05-22.tar.gz")

  detect.recipe(info)
  |> should.equal(Some(recipe.tar_gzip()))

  detect.codec(info)
  |> should.equal(Some(codec.gzip()))
}

pub fn zip_deflate_method_carries_inner_codec_test() -> Nil {
  let method = zip.deflate(level.best())

  zip.name(method)
  |> should.equal("deflate")

  zip.inner_codec(method)
  |> should.equal(Some(codec.deflate() |> codec.with_level(level: level.best())))
}

pub fn tar_helpers_build_logical_archive_test() -> Nil {
  let archive_value =
    tar.new()
    |> tar.add_file(path: "README.md", body: <<"hello":utf8>>)
    |> tar.add_directory(path: "doc")

  archive.entry_count(archive_value)
  |> should.equal(2)
}

pub fn facade_gzip_roundtrip_test() -> Nil {
  let payload = <<"hello from packkit":utf8>>
  let assert Ok(compressed) =
    packkit.compress(bytes: payload, with: codec.gzip())
  let assert Ok(restored) =
    packkit.decompress(bytes: compressed, with: codec.gzip())
  restored
  |> should.equal(payload)
}

pub fn facade_reports_unimplemented_codecs_test() -> Nil {
  // Brotli encode is not yet implemented; the facade should dispatch
  // to brotli.encode so the user sees the codec module's actual error
  // (not a stale "compress brotli" string from a facade fallthrough).
  packkit.compress(bytes: <<"x":utf8>>, with: codec.brotli())
  |> should.equal(Error(error.CodecNotImplemented(feature: "brotli.encode")))
}

pub fn facade_decompresses_brotli_stream_test() -> Nil {
  // Decoding a brotli stream through the facade must work — brotli.decode
  // is fully implemented, so packkit.decompress(..., with: codec.brotli())
  // should succeed.  Regression for the bug where the facade had no
  // `"brotli" ->` dispatch and returned `CodecNotImplemented("decompress brotli")`.
  let assert Ok(stream) =
    bit_array.base16_decode("8F0480636C6F7564792064617903")
  let assert Ok(plain) = packkit.decompress(bytes: stream, with: codec.brotli())
  plain
  |> should.equal(<<"cloudy day":utf8>>)
}

pub fn facade_pack_unpack_tar_gzip_test() -> Nil {
  let archive_value =
    tar.new()
    |> tar.add_file(path: "hello.txt", body: <<"hello":utf8>>)
    |> tar.add_file(path: "world.txt", body: <<"world":utf8>>)

  let assert Ok(bytes) =
    packkit.pack(archive_value: archive_value, using: recipe.tar_gzip())
  let assert Ok(decoded) =
    packkit.unpack(bytes: bytes, using: recipe.tar_gzip())

  archive.entry_count(decoded)
  |> should.equal(2)
}

pub fn facade_bzip2_roundtrip_test() -> Nil {
  let payload = <<"facade-level bzip2 round trip":utf8>>
  let assert Ok(compressed) =
    packkit.compress(bytes: payload, with: codec.bzip2())
  let assert Ok(restored) =
    packkit.decompress(bytes: compressed, with: codec.bzip2())
  restored
  |> should.equal(payload)
}

pub fn facade_lzw_roundtrip_test() -> Nil {
  let payload = <<"facade-level LZW round trip":utf8>>
  let assert Ok(compressed) =
    packkit.compress(bytes: payload, with: codec.lzw())
  let assert Ok(restored) =
    packkit.decompress(bytes: compressed, with: codec.lzw())
  restored
  |> should.equal(payload)
}

pub fn facade_deflate_roundtrip_test() -> Nil {
  let payload = <<"deflate via facade — fixed Huffman LZ77":utf8>>
  let assert Ok(compressed) =
    packkit.compress(bytes: payload, with: codec.deflate())
  let assert Ok(restored) =
    packkit.decompress(bytes: compressed, with: codec.deflate())
  restored
  |> should.equal(payload)
}

// -- UX additions: recipe shortcuts, detect compound, limit unchecked,
//    gzip.decode_payload, ArchiveCodecFailed structured wrapping. -----

pub fn recipe_tar_bzip2_shortcut_test() -> Nil {
  recipe.tar_bzip2()
  |> recipe.description
  |> should.equal("tar.bzip2")
}

pub fn recipe_tar_xz_shortcut_test() -> Nil {
  recipe.tar_xz()
  |> recipe.description
  |> should.equal("tar.xz")
}

pub fn recipe_tar_zstd_shortcut_test() -> Nil {
  recipe.tar_zstd()
  |> recipe.description
  |> should.equal("tar.zstd")
}

pub fn recipe_tar_brotli_shortcut_test() -> Nil {
  recipe.tar_brotli()
  |> recipe.description
  |> should.equal("tar.brotli")
}

pub fn detect_recognizes_tar_bz2_compound_test() -> Nil {
  let assert Ok(info) = detect.from_filename("backup.tar.bz2")
  detect.recipe(info)
  |> should.equal(Some(recipe.tar_bzip2()))
}

pub fn detect_recognizes_tar_xz_compound_test() -> Nil {
  let assert Ok(info) = detect.from_filename("backup.tar.xz")
  detect.recipe(info)
  |> should.equal(Some(recipe.tar_xz()))
}

pub fn detect_recognizes_tar_zst_compound_test() -> Nil {
  let assert Ok(info) = detect.from_filename("backup.tar.zst")
  detect.recipe(info)
  |> should.equal(Some(recipe.tar_zstd()))
}

pub fn facade_pack_unpack_tar_bzip2_test() -> Nil {
  // End-to-end check for the previously-broken combination.
  let archive_value =
    tar.new()
    |> tar.add_file(path: "a.txt", body: <<"alpha":utf8>>)
    |> tar.add_file(path: "b.txt", body: <<"beta":utf8>>)
  let assert Ok(bytes) =
    packkit.pack(archive_value: archive_value, using: recipe.tar_bzip2())
  let assert Ok(decoded) =
    packkit.unpack(bytes: bytes, using: recipe.tar_bzip2())
  archive.entry_count(decoded)
  |> should.equal(2)
}

pub fn pack_failure_preserves_structured_codec_error_test() -> Nil {
  // brotli encode is not implemented; the structured cause must surface
  // instead of a flattened string.
  let archive_value = tar.new() |> tar.add_file(path: "x", body: <<"y":utf8>>)
  packkit.pack(archive_value: archive_value, using: recipe.tar_brotli())
  |> should.equal(
    Error(error.ArchiveCodecFailed(
      step: "encode",
      cause: error.CodecNotImplemented(feature: "brotli.encode"),
    )),
  )
}

pub fn facade_rejects_dictionary_on_unsupported_codec_test() -> Nil {
  // Requesting a preset dictionary on a codec that does not support
  // it must fail with the typed `CodecOptionUnsupported` rather than
  // silently dropping the dictionary.
  let dict = codec.dictionary(bytes: <<"shared":utf8>>)
  let gzip_with_dict = codec.gzip() |> codec.with_dictionary(dictionary: dict)
  packkit.compress(bytes: <<"data":utf8>>, with: gzip_with_dict)
  |> should.equal(
    Error(error.CodecOptionUnsupported(option: "dictionary", codec_name: "gzip")),
  )
}

pub fn facade_rejects_level_on_levelless_codec_test() -> Nil {
  // lz4's frame format has no level knob; the codec smart constructor
  // returns level=None.  Explicit level requests must fail loudly.
  let lz4_with_level = codec.lz4() |> codec.with_level(level: level.best())
  packkit.compress(bytes: <<"data":utf8>>, with: lz4_with_level)
  |> should.equal(
    Error(error.CodecOptionUnsupported(option: "level", codec_name: "lz4")),
  )
}

pub fn facade_bzip2_default_codec_uses_canonical_level_test() -> Nil {
  // codec.bzip2() now carries level 9 — bzip2's canonical default —
  // so that `packkit.compress(bytes, with: codec.bzip2())` produces
  // the same stream as `bzip2.encode(bytes)`.
  let payload = <<"align facade bzip2 default to engine default":utf8>>
  let assert Ok(via_facade) =
    packkit.compress(bytes: payload, with: codec.bzip2())
  let assert Ok(via_engine) = bzip2.encode(bytes: payload)
  via_facade
  |> should.equal(via_engine)
}
