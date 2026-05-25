import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import packkit/archive
import packkit/codec

/// Opaque archive+codec composition.  Every public `Recipe` carries
/// an archive layer; the raw byte-to-byte path is served by the
/// codec-only `packkit.compress` / `packkit.decompress` entrypoints
/// rather than by a "headless" recipe variant, so values constructed
/// here cannot represent unusable states.
///
/// `reversed_codecs` stores codecs in outer-to-inner order so [wrap]
/// runs in O(1); accessors reverse on read.
pub opaque type Recipe {
  Recipe(format: archive.ArchiveFormat, reversed_codecs: List(codec.Codec))
}

/// Create a recipe that carries an archive but no outer codec yet.
pub fn archive_only(format format: archive.ArchiveFormat) -> Recipe {
  Recipe(format: format, reversed_codecs: [])
}

/// Create a recipe with an archive and one outer codec.
pub fn archive_with(
  format format: archive.ArchiveFormat,
  wrapped_by wrapped_by: codec.Codec,
) -> Recipe {
  archive_only(format: format) |> wrap(with: wrapped_by)
}

/// Wrap an existing recipe in one more outer codec.  O(1) thanks to
/// the reversed internal codec list.
pub fn wrap(recipe: Recipe, with outer_codec: codec.Codec) -> Recipe {
  Recipe(..recipe, reversed_codecs: [outer_codec, ..recipe.reversed_codecs])
}

/// Convenience constructor for `tar.gz`.
pub fn tar_gzip() -> Recipe {
  archive_with(format: archive.tar(), wrapped_by: codec.gzip())
}

/// Convenience constructor for `tar.zlib`.
pub fn tar_zlib() -> Recipe {
  archive_with(format: archive.tar(), wrapped_by: codec.zlib())
}

/// Convenience constructor for `tar.lz4`.
pub fn tar_lz4() -> Recipe {
  archive_with(format: archive.tar(), wrapped_by: codec.lz4())
}

/// Convenience constructor for `tar.snappy`.
pub fn tar_snappy() -> Recipe {
  archive_with(format: archive.tar(), wrapped_by: codec.snappy())
}

/// Convenience constructor for `tar.bz2`.
pub fn tar_bzip2() -> Recipe {
  archive_with(format: archive.tar(), wrapped_by: codec.bzip2())
}

/// Convenience constructor for `tar.xz`.
pub fn tar_xz() -> Recipe {
  archive_with(format: archive.tar(), wrapped_by: codec.xz())
}

/// Convenience constructor for `tar.zst`.
pub fn tar_zstd() -> Recipe {
  archive_with(format: archive.tar(), wrapped_by: codec.zstd())
}

/// Convenience constructor for `tar.Z` (Unix compress / LZW).
pub fn tar_lzw() -> Recipe {
  archive_with(format: archive.tar(), wrapped_by: codec.lzw())
}

/// Convenience constructor for `tar.br`.  Round-trips end-to-end via
/// brotli's uncompressed-metablock encoder; the bytes are valid for
/// any conforming brotli decoder but do no actual LZ77/Huffman
/// compression yet.
pub fn tar_brotli() -> Recipe {
  archive_with(format: archive.tar(), wrapped_by: codec.brotli())
}

/// Convenience constructor for `cpio.gz`.
pub fn cpio_gzip() -> Recipe {
  archive_with(format: archive.cpio_newc(), wrapped_by: codec.gzip())
}

/// `cpio.bz2` recipe — cpio body, bzip2-compressed envelope.
pub fn cpio_bzip2() -> Recipe {
  archive_with(format: archive.cpio_newc(), wrapped_by: codec.bzip2())
}

/// `cpio.xz` recipe — cpio body, xz-compressed envelope.
pub fn cpio_xz() -> Recipe {
  archive_with(format: archive.cpio_newc(), wrapped_by: codec.xz())
}

/// `cpio.zst` recipe — cpio body, zstd-compressed envelope.
pub fn cpio_zstd() -> Recipe {
  archive_with(format: archive.cpio_newc(), wrapped_by: codec.zstd())
}

/// Convenience constructor for a bare `tar` archive (no outer codec).
/// Equivalent to `archive_only(format: archive.tar())`; provided so
/// the same `packkit.pack` / `packkit.unpack` entrypoints serve both
/// uncompressed tar and codec-wrapped tar without the caller switching
/// to `packkit.write` / `packkit.read`.
pub fn tar() -> Recipe {
  archive_only(format: archive.tar())
}

/// Convenience constructor for a bare ZIP archive.  ZIP carries its
/// own per-entry compression internally, so there's no recipe-level
/// codec to wrap it in — but exposing `recipe.zip()` lets callers use
/// the same `packkit.pack` / `packkit.unpack` API they use for tar
/// recipes, instead of switching to `packkit.write` / `packkit.read`.
pub fn zip() -> Recipe {
  archive_only(format: archive.zip())
}

/// Convenience constructor for a bare 7z archive.  Like ZIP, 7z
/// applies its own internal compression and does not take a recipe
/// codec wrapper; this constructor keeps the API symmetric across
/// archive families.
pub fn seven_z() -> Recipe {
  archive_only(format: archive.seven_z())
}

/// Convenience constructor for a bare `ar` archive (BSD long-name
/// format on encode; GNU string-table form also accepted on decode).
pub fn ar() -> Recipe {
  archive_only(format: archive.ar())
}

/// Convenience constructor for a bare cpio (newc) archive.
pub fn cpio() -> Recipe {
  archive_only(format: archive.cpio_newc())
}

/// Read the archive format the recipe was constructed with.
pub fn archive_format(recipe: Recipe) -> archive.ArchiveFormat {
  recipe.format
}

/// Read the codec chain in inner-to-outer order.
pub fn codecs(recipe: Recipe) -> List(codec.Codec) {
  list.reverse(recipe.reversed_codecs)
}

/// Read the outermost codec, if any.
pub fn outermost_codec(recipe: Recipe) -> Option(codec.Codec) {
  case recipe.reversed_codecs {
    [head, ..] -> Some(head)
    [] -> None
  }
}

/// Human-readable canonical description for debugging and tests.
pub fn description(recipe: Recipe) -> String {
  [archive.name(recipe.format), ..list.map(codecs(recipe), codec.name)]
  |> string.join(with: ".")
}
