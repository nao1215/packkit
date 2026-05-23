import gleam/bit_array
import gleam/option.{type Option, None, Some}
import gleam/string
import packkit/archive
import packkit/codec
import packkit/error
import packkit/recipe

/// Opaque detection result. Callers inspect it through accessors rather
/// than through public constructors.
pub opaque type Detected {
  Detected(
    codec: Option(codec.Codec),
    archive: Option(archive.ArchiveFormat),
    recipe: Option(recipe.Recipe),
    extension: Option(String),
  )
}

/// Detect a format from a filename or path suffix.
pub fn from_filename(path: String) -> Result(Detected, error.DetectError) {
  let lower = string.lowercase(path)
  case find_filename_match(lower, filename_rules()) {
    Some(detected) -> Ok(detected)
    None -> Error(error.DetectUnknownFormat(input: path))
  }
}

/// Filename rules, ordered most-specific first so the first match wins.
/// Compound extensions (`.tar.gz`, `.tar.bz2`, …) must precede the
/// single extensions (`.gz`, `.bz2`, …) for the obvious reason.
fn filename_rules() -> List(#(List(String), fn() -> Detected)) {
  [
    // Compound archive+codec recipes.
    #([".tar.gz", ".tgz"], fn() {
      detected_recipe(recipe.tar_gzip(), extension: "tar.gz")
    }),
    #([".tar.zlib"], fn() {
      detected_recipe(recipe.tar_zlib(), extension: "tar.zlib")
    }),
    #([".tar.lz4"], fn() {
      detected_recipe(recipe.tar_lz4(), extension: "tar.lz4")
    }),
    #([".tar.sz", ".tar.snappy"], fn() {
      detected_recipe(recipe.tar_snappy(), extension: "tar.snappy")
    }),
    #([".tar.bz2"], fn() {
      detected_recipe(recipe.tar_bzip2(), extension: "tar.bz2")
    }),
    #([".tar.xz"], fn() {
      detected_recipe(recipe.tar_xz(), extension: "tar.xz")
    }),
    #([".tar.zst"], fn() {
      detected_recipe(recipe.tar_zstd(), extension: "tar.zst")
    }),
    #([".tar.br"], fn() {
      detected_recipe(recipe.tar_brotli(), extension: "tar.br")
    }),
    #([".cpio.gz"], fn() {
      detected_recipe(recipe.cpio_gzip(), extension: "cpio.gz")
    }),
    // Archive families.
    #([".tar"], fn() { detected_archive(archive.tar(), extension: "tar") }),
    #([".zip"], fn() { detected_archive(archive.zip(), extension: "zip") }),
    #([".7z"], fn() { detected_archive(archive.seven_z(), extension: "7z") }),
    #([".cpio"], fn() {
      detected_archive(archive.cpio_newc(), extension: "cpio")
    }),
    #([".ar", ".a"], fn() { detected_archive(archive.ar(), extension: "ar") }),
    // Single-codec extensions.
    #([".gz"], fn() { detected_codec(codec.gzip(), extension: "gz") }),
    #([".zlib"], fn() { detected_codec(codec.zlib(), extension: "zlib") }),
    #([".deflate", ".dfl"], fn() {
      detected_codec(codec.deflate(), extension: "deflate")
    }),
    #([".lz4"], fn() { detected_codec(codec.lz4_frame(), extension: "lz4") }),
    #([".sz", ".snappy"], fn() {
      detected_codec(codec.snappy_frame(), extension: "snappy")
    }),
    #([".bz2"], fn() { detected_codec(codec.bzip2(), extension: "bz2") }),
    #([".xz"], fn() { detected_codec(codec.xz(), extension: "xz") }),
    #([".br"], fn() { detected_codec(codec.brotli(), extension: "br") }),
    #([".zst"], fn() { detected_codec(codec.zstd(), extension: "zst") }),
    #([".z"], fn() { detected_codec(codec.lzw(), extension: "Z") }),
  ]
}

fn find_filename_match(
  path: String,
  rules: List(#(List(String), fn() -> Detected)),
) -> Option(Detected) {
  case rules {
    [] -> None
    [#(suffixes, build), ..rest] ->
      case matches_any(path, suffixes) {
        True -> Some(build())
        False -> find_filename_match(path, rest)
      }
  }
}

/// Detect a format from the leading bytes of an input stream.
pub fn from_bytes(bytes: BitArray) -> Result(Detected, error.DetectError) {
  // Gzip: 1F 8B 08
  case bytes {
    <<0x1F, 0x8B, _:bytes>> -> Ok(detected_codec(codec.gzip(), extension: "gz"))
    <<0x78, _flg, _:bytes>> ->
      Ok(detected_codec(codec.zlib(), extension: "zlib"))
    <<0x50, 0x4B, 0x03, 0x04, _:bytes>> ->
      Ok(detected_archive(archive.zip(), extension: "zip"))
    <<0x50, 0x4B, 0x05, 0x06, _:bytes>> ->
      Ok(detected_archive(archive.zip(), extension: "zip"))
    <<0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, _:bytes>> ->
      Ok(detected_archive(archive.seven_z(), extension: "7z"))
    <<0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00, _:bytes>> ->
      Ok(detected_codec(codec.xz(), extension: "xz"))
    <<0x28, 0xB5, 0x2F, 0xFD, _:bytes>> ->
      Ok(detected_codec(codec.zstd(), extension: "zst"))
    <<0x04, 0x22, 0x4D, 0x18, _:bytes>> ->
      Ok(detected_codec(codec.lz4_frame(), extension: "lz4"))
    <<0x42, 0x5A, 0x68, _:bytes>> ->
      Ok(detected_codec(codec.bzip2(), extension: "bz2"))
    <<0x1F, 0x9D, _:bytes>> -> Ok(detected_codec(codec.lzw(), extension: "Z"))
    <<"!<arch>\n":utf8, _:bytes>> ->
      Ok(detected_archive(archive.ar(), extension: "ar"))
    <<"070701":utf8, _:bytes>> ->
      Ok(detected_archive(archive.cpio_newc(), extension: "cpio"))
    _ ->
      case has_ustar_magic(bytes) {
        True -> Ok(detected_archive(archive.tar(), extension: "tar"))
        False -> Error(error.DetectUnknownFormat(input: "byte-signature scan"))
      }
  }
}

fn has_ustar_magic(bytes: BitArray) -> Bool {
  case bit_array.slice(bytes, 257, 5) {
    Ok(<<"ustar":utf8>>) -> True
    _ -> False
  }
}

/// Read the detected codec if one was found.
pub fn codec_of(detected: Detected) -> Option(codec.Codec) {
  detected.codec
}

/// Read the detected archive family if one was found.
pub fn archive_of(detected: Detected) -> Option(archive.ArchiveFormat) {
  detected.archive
}

/// Read the detected recipe if one was found.
pub fn recipe_of(detected: Detected) -> Option(recipe.Recipe) {
  detected.recipe
}

/// Read the matched extension label, if any.
pub fn extension_of(detected: Detected) -> Option(String) {
  detected.extension
}

fn detected_recipe(
  value: recipe.Recipe,
  extension extension: String,
) -> Detected {
  Detected(
    codec: recipe.outermost_codec(value),
    archive: recipe.archive_format(value),
    recipe: Some(value),
    extension: Some(extension),
  )
}

fn detected_archive(
  value: archive.ArchiveFormat,
  extension extension: String,
) -> Detected {
  Detected(
    codec: None,
    archive: Some(value),
    recipe: None,
    extension: Some(extension),
  )
}

fn detected_codec(value: codec.Codec, extension extension: String) -> Detected {
  Detected(
    codec: Some(value),
    archive: None,
    recipe: None,
    extension: Some(extension),
  )
}

fn matches_any(path: String, suffixes: List(String)) -> Bool {
  case suffixes {
    [] -> False
    [suffix, ..rest] ->
      string.ends_with(path, suffix) || matches_any(path, rest)
  }
}
