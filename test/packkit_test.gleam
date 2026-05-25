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
import packkit/limit
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
  |> should.equal(entry.File)

  file
  |> entry.path
  |> entry.depth
  |> should.equal(3)
}

pub fn tar_gzip_recipe_exposes_archive_and_outer_codec_test() -> Nil {
  let plan = recipe.tar_gzip()

  recipe.archive_format(plan)
  |> should.equal(archive.tar())

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

pub fn facade_brotli_round_trip_test() -> Nil {
  // Brotli encode now emits uncompressed metablocks, so the facade
  // can round-trip end-to-end.  Regression for the period when the
  // encoder returned `CodecNotImplemented`.
  let payload = <<"facade-level brotli round trip":utf8>>
  let assert Ok(stream) = packkit.compress(bytes: payload, with: codec.brotli())
  let assert Ok(restored) =
    packkit.decompress(bytes: stream, with: codec.brotli())
  restored
  |> should.equal(payload)
}

pub fn facade_pack_unpack_tar_brotli_test() -> Nil {
  // tar.brotli now round-trips because brotli.encode is wired and the
  // facade no longer rejects the recipe at encode time.
  let archive_value =
    tar.new()
    |> tar.add_file(path: "alpha.txt", body: <<"alpha":utf8>>)
    |> tar.add_file(path: "beta.txt", body: <<"beta":utf8>>)
  let assert Ok(bytes) =
    packkit.pack(archive_value: archive_value, using: recipe.tar_brotli())
  let assert Ok(decoded) =
    packkit.unpack(bytes: bytes, using: recipe.tar_brotli())
  archive.entry_count(decoded)
  |> should.equal(2)
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

pub fn facade_pack_unpack_via_recipe_zip_test() -> Nil {
  // `recipe.zip()` is the bare-archive convenience shortcut introduced
  // so callers can stay on the `packkit.pack` / `packkit.unpack` API
  // when targeting ZIP instead of switching to `packkit.write` /
  // `packkit.read`.  The same archive value must round-trip through
  // both paths byte-for-byte.
  let archive_value =
    zip.new()
    |> archive.add(entry: entry.file(path: "hello.txt", body: <<"hello":utf8>>))
    |> archive.add(entry: entry.file(path: "world.txt", body: <<"world":utf8>>))

  let assert Ok(bytes) =
    packkit.pack(archive_value: archive_value, using: recipe.zip())
  let assert Ok(decoded) =
    packkit.unpack(bytes: bytes, using: recipe.zip())

  archive.entry_count(decoded)
  |> should.equal(2)
}

pub fn facade_pack_unpack_via_recipe_tar_bare_test() -> Nil {
  // `recipe.tar()` covers the uncompressed-tar case via the same
  // pack/unpack API.  Without the convenience shortcut callers had to
  // either write `recipe.archive_only(format: archive.tar())` or fall
  // through to `packkit.write` / `packkit.read`.
  let archive_value =
    tar.new()
    |> tar.add_file(path: "a.txt", body: <<"a":utf8>>)
    |> tar.add_file(path: "b.txt", body: <<"b":utf8>>)
  let assert Ok(bytes) =
    packkit.pack(archive_value: archive_value, using: recipe.tar())
  let assert Ok(decoded) =
    packkit.unpack(bytes: bytes, using: recipe.tar())
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
  // When a codec step inside a recipe fails, the structured cause
  // must surface instead of a flattened string.  We trigger a failure
  // by requesting a preset dictionary on a codec that does not
  // support one (gzip), which the facade rejects with the typed
  // `CodecOptionUnsupported`.
  let archive_value = tar.new() |> tar.add_file(path: "x", body: <<"y":utf8>>)
  let gzip_with_dict =
    codec.gzip()
    |> codec.with_dictionary(dictionary: codec.dictionary(bytes: <<"d":utf8>>))
  let dict_recipe =
    recipe.archive_with(format: archive.tar(), wrapped_by: gzip_with_dict)
  packkit.pack(archive_value: archive_value, using: dict_recipe)
  |> should.equal(
    Error(error.ArchiveCodecFailed(
      step: "encode",
      cause: error.CodecOptionUnsupported(
        option: "dictionary",
        codec_name: "gzip",
      ),
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

pub fn write_rejects_format_mismatch_test() -> Nil {
  // An `Archive` is bound to one format at construction time. Asking
  // `packkit.write` to serialise it as a different format would silently
  // corrupt the output, so the facade refuses with a typed error.
  let tar_archive = tar.new() |> tar.add_file(path: "x.txt", body: <<"x":utf8>>)
  packkit.write(archive_value: tar_archive, format: archive.zip())
  |> should.equal(
    Error(error.ArchiveFormatMismatch(archive: "tar", requested: "zip")),
  )
}

pub fn write_accepts_matching_format_test() -> Nil {
  let tar_archive = tar.new() |> tar.add_file(path: "x.txt", body: <<"x":utf8>>)
  case packkit.write(archive_value: tar_archive, format: archive.tar()) {
    Ok(_) -> Nil
    _ -> should.fail()
  }
}

pub fn pack_rejects_recipe_format_mismatch_test() -> Nil {
  // The recipe declares the archive layer; if the supplied archive
  // value was constructed for a different format, `pack` must refuse
  // before touching the codec chain.
  let zip_archive_value =
    zip.new() |> archive.add(entry: entry.file(path: "x", body: <<"x":utf8>>))

  packkit.pack(archive_value: zip_archive_value, using: recipe.tar_gzip())
  |> should.equal(
    Error(error.ArchiveFormatMismatch(archive: "zip", requested: "tar")),
  )
}

pub fn decompress_with_limits_propagates_input_limit_test() -> Nil {
  // The supplied Limits value must reach the underlying codec; if it
  // didn't, an oversized stream would still decode under the codec's
  // own default limits.  Use gzip because it has a cheap, deterministic
  // encoding for any payload.
  let payload = <<"limits propagation regression":utf8>>
  let assert Ok(stream) = packkit.compress(bytes: payload, with: codec.gzip())
  let tight =
    limit.default()
    |> limit.with_max_input_bytes(bytes: 4)
  case
    packkit.decompress_with_limits(
      bytes: stream,
      with: codec.gzip(),
      limits: tight,
    )
  {
    Error(error.CodecLimitExceeded(limit: "max_input_bytes", actual: _)) -> Nil
    _ -> should.fail()
  }
}

pub fn decompress_with_limits_identity_enforces_input_limit_test() -> Nil {
  // Even the identity codec must observe `max_input_bytes` when given
  // explicit limits, so the no-op path is consistent with every other
  // codec.
  let tight = limit.default() |> limit.with_max_input_bytes(bytes: 4)
  case
    packkit.decompress_with_limits(
      bytes: <<"longer than 4":utf8>>,
      with: codec.identity(),
      limits: tight,
    )
  {
    Error(error.CodecLimitExceeded(limit: "max_input_bytes", actual: _)) -> Nil
    _ -> should.fail()
  }
}

pub fn read_with_limits_propagates_to_archive_decoder_test() -> Nil {
  // `packkit.read_with_limits` must hand the Limits to the archive
  // family's `decode_with_limits` rather than re-defaulting them.
  let archive_value =
    tar.new()
    |> tar.add_file(path: "a.txt", body: <<>>)
    |> tar.add_file(path: "b.txt", body: <<>>)
    |> tar.add_file(path: "c.txt", body: <<>>)
  let assert Ok(bytes) =
    packkit.write(archive_value: archive_value, format: tar.format())
  let tight = limit.default() |> limit.with_max_members(count: 2)
  case
    packkit.read_with_limits(bytes: bytes, format: tar.format(), limits: tight)
  {
    Error(error.ArchiveLimitExceeded(limit: "max_members", actual: _)) -> Nil
    _ -> should.fail()
  }
}

pub fn unpack_with_limits_propagates_to_codec_chain_test() -> Nil {
  // `unpack_with_limits` must thread Limits through both the codec
  // chain *and* the archive decoder.  Hit the codec leg by setting a
  // tight max_input_bytes that's smaller than the packed gzip stream.
  let archive_value =
    tar.new() |> tar.add_file(path: "a.txt", body: <<"a":utf8>>)
  let assert Ok(bytes) =
    packkit.pack(archive_value: archive_value, using: recipe.tar_gzip())
  let tight = limit.default() |> limit.with_max_input_bytes(bytes: 4)
  case
    packkit.unpack_with_limits(
      bytes: bytes,
      using: recipe.tar_gzip(),
      limits: tight,
    )
  {
    Error(error.ArchiveCodecFailed(
      step: "decode",
      cause: error.CodecLimitExceeded(limit: "max_input_bytes", actual: _),
    )) -> Nil
    _ -> should.fail()
  }
}

pub fn compress_rejects_non_default_level_on_zlib_test() -> Nil {
  // The zlib encoder delegates to a fixed-Huffman DEFLATE backend with
  // no level knob.  A caller-supplied non-default level used to be
  // silently dropped on the floor; it must now surface a typed
  // `CodecOptionUnsupported`.
  let zlib_with_best = codec.zlib() |> codec.with_level(level: level.best())
  packkit.compress(bytes: <<"x":utf8>>, with: zlib_with_best)
  |> should.equal(
    Error(error.CodecOptionUnsupported(option: "level", codec_name: "zlib")),
  )
}

pub fn compress_rejects_non_default_level_on_gzip_test() -> Nil {
  let gzip_with_best = codec.gzip() |> codec.with_level(level: level.best())
  packkit.compress(bytes: <<"x":utf8>>, with: gzip_with_best)
  |> should.equal(
    Error(error.CodecOptionUnsupported(option: "level", codec_name: "gzip")),
  )
}

pub fn compress_rejects_non_default_level_on_xz_test() -> Nil {
  let xz_with_best = codec.xz() |> codec.with_level(level: level.fast())
  packkit.compress(bytes: <<"x":utf8>>, with: xz_with_best)
  |> should.equal(
    Error(error.CodecOptionUnsupported(option: "level", codec_name: "xz")),
  )
}

pub fn compress_accepts_default_level_on_fixed_level_codecs_test() -> Nil {
  // The smart constructors carry `level.default()` by design; that
  // should still round-trip cleanly.
  let payload = <<"fixed-level default still works":utf8>>
  let assert Ok(out_xz) = packkit.compress(bytes: payload, with: codec.xz())
  let assert Ok(restored_xz) =
    packkit.decompress(bytes: out_xz, with: codec.xz())
  restored_xz
  |> should.equal(payload)
  let assert Ok(out_gzip) = packkit.compress(bytes: payload, with: codec.gzip())
  let assert Ok(restored_gzip) =
    packkit.decompress(bytes: out_gzip, with: codec.gzip())
  restored_gzip
  |> should.equal(payload)
}

pub fn compress_identity_rejects_level_test() -> Nil {
  // The identity codec carries no level by default, so a
  // caller-supplied level is unambiguously a request the codec cannot
  // honour.
  let identity_with_level =
    codec.identity() |> codec.with_level(level: level.best())
  packkit.compress(bytes: <<"data":utf8>>, with: identity_with_level)
  |> should.equal(
    Error(error.CodecOptionUnsupported(option: "level", codec_name: "identity")),
  )
}

pub fn archive_add_preserves_observable_order_test() -> Nil {
  // The O(1) builder stores entries reversed internally; `entries`
  // must restore the observable insertion order after the refactor.
  let archive_value =
    tar.new()
    |> tar.add_file(path: "a.txt", body: <<"a":utf8>>)
    |> tar.add_file(path: "b.txt", body: <<"b":utf8>>)
    |> tar.add_file(path: "c.txt", body: <<"c":utf8>>)

  archive.entries(archive_value)
  |> list_map_paths
  |> should.equal(["a.txt", "b.txt", "c.txt"])

  archive.entry_count(archive_value)
  |> should.equal(3)
}

pub fn archive_from_entries_preserves_order_test() -> Nil {
  let assert Ok(a) = entry.file_checked(path: "a", body: <<>>)
  let assert Ok(b) = entry.file_checked(path: "b", body: <<>>)
  let assert Ok(c) = entry.file_checked(path: "c", body: <<>>)
  let archive_value =
    archive.from_entries(format: tar.format(), entries: [a, b, c])
  archive.entries(archive_value)
  |> list_map_paths
  |> should.equal(["a", "b", "c"])
}

pub fn recipe_wrap_preserves_inner_to_outer_order_test() -> Nil {
  // The reversed internal storage must surface inner-to-outer order
  // through the `codecs` accessor.
  let plan =
    recipe.archive_with(format: archive.tar(), wrapped_by: codec.gzip())
    |> recipe.wrap(with: codec.bzip2())
    |> recipe.wrap(with: codec.lz4())

  recipe.codecs(plan)
  |> list_map_codec_names
  |> should.equal(["gzip", "bzip2", "lz4"])

  recipe.outermost_codec(plan)
  |> should.equal(Some(codec.lz4()))
}

fn list_map_paths(entries: List(entry.Entry)) -> List(String) {
  case entries {
    [] -> []
    [head, ..rest] -> [
      entry.to_string(entry.path(head)),
      ..list_map_paths(rest)
    ]
  }
}

fn list_map_codec_names(codecs: List(codec.Codec)) -> List(String) {
  case codecs {
    [] -> []
    [head, ..rest] -> [codec.name(head), ..list_map_codec_names(rest)]
  }
}

pub fn archive_add_file_works_for_every_format_test() -> Nil {
  // The shared `archive.add_file` helper must work for every format
  // (tar/cpio/ar/zip/seven_z), not only the one tar exposes a
  // convenience helper for.  Regression for the pre-release API gap
  // where each archive module had to duplicate `add_*` helpers (or
  // users had to drop down to `entry.file |> archive.add`).
  let tar_archive =
    archive.new(format: archive.tar())
    |> archive.add_file(path: "a.txt", body: <<"a":utf8>>)
  archive.entry_count(tar_archive)
  |> should.equal(1)

  let cpio_archive =
    archive.new(format: archive.cpio_newc())
    |> archive.add_file(path: "a.txt", body: <<"a":utf8>>)
  archive.entry_count(cpio_archive)
  |> should.equal(1)

  let zip_archive =
    archive.new(format: archive.zip())
    |> archive.add_file(path: "a.txt", body: <<"a":utf8>>)
  archive.entry_count(zip_archive)
  |> should.equal(1)

  let ar_archive =
    archive.new(format: archive.ar())
    |> archive.add_file(path: "a.txt", body: <<"a":utf8>>)
  archive.entry_count(ar_archive)
  |> should.equal(1)
}

pub fn archive_add_directory_and_symlink_helpers_test() -> Nil {
  let arch =
    archive.new(format: archive.tar())
    |> archive.add_directory(path: "doc")
    |> archive.add_symlink(path: "link.txt", target: "actual.txt")
    |> archive.add_hardlink(path: "hard.txt", target: "actual.txt")
  archive.entry_count(arch)
  |> should.equal(3)
}

pub fn archive_add_file_checked_rejects_absolute_path_test() -> Nil {
  // The checked variant must surface entry-validation errors instead
  // of panicking — drop-in replacement for `entry.file_checked |>
  // archive.add` callers.
  archive.add_file_checked(
    archive: archive.new(format: archive.tar()),
    path: "/etc/passwd",
    body: <<"data":utf8>>,
  )
  |> should.equal(Error(entry.AbsolutePath("/etc/passwd")))
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
