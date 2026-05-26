import gleam/bit_array
import gleam/int
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

/// Try filename detection first, then fall back to magic-byte
/// detection on the supplied content.  Mirrors the resolution order
/// most CLI tools use: a meaningful extension is a strong signal, but
/// when the path is uninformative (`-`, `/dev/stdin`, an arbitrary
/// upload, etc.) the file's first bytes still pin the format.
///
/// The returned `Detected` carries whichever path produced the hit; on
/// failure the typed error mentions the path attempted last so the
/// message stays specific to the user's input.
pub fn from_path_or_bytes(
  path path: String,
  bytes bytes: BitArray,
) -> Result(Detected, error.DetectError) {
  case from_filename(path) {
    Ok(detected) -> Ok(detected)
    Error(_) -> from_bytes(bytes)
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
    #([".tar.z", ".taz"], fn() {
      detected_recipe(recipe.tar_lzw(), extension: "tar.Z")
    }),
    #([".cpio.gz"], fn() {
      detected_recipe(recipe.cpio_gzip(), extension: "cpio.gz")
    }),
    #([".cpio.bz2"], fn() {
      detected_recipe(recipe.cpio_bzip2(), extension: "cpio.bz2")
    }),
    #([".cpio.xz"], fn() {
      detected_recipe(recipe.cpio_xz(), extension: "cpio.xz")
    }),
    #([".cpio.zst"], fn() {
      detected_recipe(recipe.cpio_zstd(), extension: "cpio.zst")
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
    #([".lz4"], fn() { detected_codec(codec.lz4(), extension: "lz4") }),
    #([".sz", ".snappy"], fn() {
      detected_codec(codec.snappy(), extension: "snappy")
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
///
/// Signatures are matched as strictly as practical:
///
/// * gzip (`1F 8B`) also requires the compression-method byte to be
///   `08` (DEFLATE), since RFC 1952 reserves the other values and
///   no production gzip stream uses them.
/// * zlib (`78 _`) requires CMF.CM == 8 (DEFLATE), CMF.CINFO ≤ 7
///   (15-bit window), and `(CMF*256 + FLG) % 31 == 0` per RFC 1950.
/// * bzip2 (`BZh`) additionally requires the block-size byte to be
///   an ASCII digit `1`..`9`.
/// * lz4 (`04 22 4D 18`) and `.Z` (`1F 9D`) keep their fixed magic.
/// * zstd skippable frames (magic `184D2A50`..`184D2A5F`) are
///   recognised as zstd so wrappers that embed user metadata in
///   skippable frames at the start of the stream do not fail to
///   detect.
/// * snappy framed format starts with a stream identifier chunk
///   (`FF 06 00 00 sNaPpY`); the raw snappy block format has no
///   magic so it can only be detected from filename.
///
/// Looser signatures like a bare `0x78 _` would false-positive on
/// any byte stream whose first byte happens to be `0x78`.
pub fn from_bytes(bytes: BitArray) -> Result(Detected, error.DetectError) {
  case bytes {
    <<0x1F, 0x8B, cm, _:bytes>> if cm == 0x08 ->
      Ok(detected_codec(codec.gzip(), extension: "gz"))
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
    // zstd skippable frame magic: 0x184D2A50..0x184D2A5F (little-endian).
    // The low nibble of the first byte varies (0..F); the high nibble
    // is always 5 and bytes 1..3 are fixed.
    <<low, 0x2A, 0x4D, 0x18, _:bytes>> if low >= 0x50 && low <= 0x5F ->
      Ok(detected_codec(codec.zstd(), extension: "zst"))
    <<0x04, 0x22, 0x4D, 0x18, _:bytes>> ->
      Ok(detected_codec(codec.lz4(), extension: "lz4"))
    // LZ4 legacy frame format (magic 0x184C2102, little-endian) is
    // emitted by older `lz4 -l` / `lz4c` tools.  The packkit lz4
    // codec recognises this magic and decodes through
    // `decode_legacy_blocks`, so detection routes the byte stream
    // straight to a working decoder.
    <<0x02, 0x21, 0x4C, 0x18, _:bytes>> ->
      Ok(detected_codec(codec.lz4(), extension: "lz4"))
    // Snappy framed stream identifier chunk:
    //   chunk_type 0xFF, chunk_length 6 (LE 24-bit), body "sNaPpY".
    <<0xFF, 0x06, 0x00, 0x00, "sNaPpY":utf8, _:bytes>> ->
      Ok(detected_codec(codec.snappy(), extension: "snappy"))
    <<0x42, 0x5A, 0x68, lvl, _:bytes>> if lvl >= 0x31 && lvl <= 0x39 ->
      Ok(detected_codec(codec.bzip2(), extension: "bz2"))
    <<0x1F, 0x9D, _:bytes>> -> Ok(detected_codec(codec.lzw(), extension: "Z"))
    <<"!<arch>\n":utf8, _:bytes>> ->
      Ok(detected_archive(archive.ar(), extension: "ar"))
    <<"070701":utf8, _:bytes>> ->
      Ok(detected_archive(archive.cpio_newc(), extension: "cpio"))
    _ ->
      case looks_like_zlib(bytes) {
        True -> Ok(detected_codec(codec.zlib(), extension: "zlib"))
        False ->
          case has_ustar_magic(bytes) {
            True -> Ok(detected_archive(archive.tar(), extension: "tar"))
            False ->
              Error(error.DetectUnknownFormat(input: "byte-signature scan"))
          }
      }
  }
}

fn looks_like_zlib(bytes: BitArray) -> Bool {
  case bytes {
    <<cmf, flg, _:bytes>> -> {
      let cm = int.bitwise_and(cmf, 0x0F)
      let cinfo = int.bitwise_shift_right(cmf, 4)
      cm == 8 && cinfo <= 7 && { cmf * 256 + flg } % 31 == 0
    }
    _ -> False
  }
}

fn has_ustar_magic(bytes: BitArray) -> Bool {
  case bit_array.slice(bytes, 257, 5) {
    Ok(<<"ustar":utf8>>) -> True
    _ -> False
  }
}

/// Read the detected codec if one was found.
pub fn codec(detected: Detected) -> Option(codec.Codec) {
  detected.codec
}

/// Read the detected archive family if one was found.
pub fn archive(detected: Detected) -> Option(archive.ArchiveFormat) {
  detected.archive
}

/// Read the detected recipe if one was found.
pub fn recipe(detected: Detected) -> Option(recipe.Recipe) {
  detected.recipe
}

/// Read the matched extension label, if any.
pub fn extension(detected: Detected) -> Option(String) {
  detected.extension
}

fn detected_recipe(
  value: recipe.Recipe,
  extension extension: String,
) -> Detected {
  Detected(
    codec: recipe.outermost_codec(value),
    archive: Some(recipe.archive_format(value)),
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
