import gleam/option.{Some}
import gleeunit
import gleeunit/should
import packkit
import packkit/archive
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
  |> entry.path_of
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

  detect.recipe_of(info)
  |> should.equal(Some(recipe.tar_gzip()))

  detect.codec_of(info)
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
  packkit.compress(bytes: <<"x":utf8>>, with: codec.brotli())
  |> should.equal(Error(error.CodecNotImplemented(feature: "compress brotli")))
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
