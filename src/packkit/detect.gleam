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

  case matches_any(lower, [".tar.gz", ".tgz"]) {
    True -> Ok(detected_recipe(recipe.tar_gzip(), extension: "tar.gz"))
    False ->
      case string.ends_with(lower, ".tar.zlib") {
        True -> Ok(detected_recipe(recipe.tar_zlib(), extension: "tar.zlib"))
        False ->
          case string.ends_with(lower, ".tar.lz4") {
            True -> Ok(detected_recipe(recipe.tar_lz4(), extension: "tar.lz4"))
            False ->
              case matches_any(lower, [".tar.sz", ".tar.snappy"]) {
                True ->
                  Ok(detected_recipe(
                    recipe.tar_snappy(),
                    extension: "tar.snappy",
                  ))
                False ->
                  case string.ends_with(lower, ".cpio.gz") {
                    True ->
                      Ok(detected_recipe(
                        recipe.cpio_gzip(),
                        extension: "cpio.gz",
                      ))
                    False ->
                      case string.ends_with(lower, ".tar") {
                        True ->
                          Ok(detected_archive(archive.tar(), extension: "tar"))
                        False ->
                          case string.ends_with(lower, ".zip") {
                            True ->
                              Ok(detected_archive(
                                archive.zip(),
                                extension: "zip",
                              ))
                            False ->
                              case string.ends_with(lower, ".7z") {
                                True ->
                                  Ok(detected_archive(
                                    archive.seven_z(),
                                    extension: "7z",
                                  ))
                                False ->
                                  case string.ends_with(lower, ".cpio") {
                                    True ->
                                      Ok(detected_archive(
                                        archive.cpio_newc(),
                                        extension: "cpio",
                                      ))
                                    False ->
                                      case matches_any(lower, [".ar", ".a"]) {
                                        True ->
                                          Ok(detected_archive(
                                            archive.ar(),
                                            extension: "ar",
                                          ))
                                        False ->
                                          case string.ends_with(lower, ".gz") {
                                            True ->
                                              Ok(detected_codec(
                                                codec.gzip(),
                                                extension: "gz",
                                              ))
                                            False ->
                                              case
                                                string.ends_with(lower, ".zlib")
                                              {
                                                True ->
                                                  Ok(detected_codec(
                                                    codec.zlib(),
                                                    extension: "zlib",
                                                  ))
                                                False ->
                                                  case
                                                    matches_any(lower, [
                                                      ".deflate",
                                                      ".dfl",
                                                    ])
                                                  {
                                                    True ->
                                                      Ok(detected_codec(
                                                        codec.deflate(),
                                                        extension: "deflate",
                                                      ))
                                                    False ->
                                                      case
                                                        string.ends_with(
                                                          lower,
                                                          ".lz4",
                                                        )
                                                      {
                                                        True ->
                                                          Ok(detected_codec(
                                                            codec.lz4_frame(),
                                                            extension: "lz4",
                                                          ))
                                                        False ->
                                                          case
                                                            matches_any(lower, [
                                                              ".sz",
                                                              ".snappy",
                                                            ])
                                                          {
                                                            True ->
                                                              Ok(detected_codec(
                                                                codec.snappy_frame(),
                                                                extension: "snappy",
                                                              ))
                                                            False ->
                                                              case
                                                                string.ends_with(
                                                                  lower,
                                                                  ".bz2",
                                                                )
                                                              {
                                                                True ->
                                                                  Ok(
                                                                    detected_codec(
                                                                      codec.bzip2(),
                                                                      extension: "bz2",
                                                                    ),
                                                                  )
                                                                False ->
                                                                  case
                                                                    string.ends_with(
                                                                      lower,
                                                                      ".xz",
                                                                    )
                                                                  {
                                                                    True ->
                                                                      Ok(
                                                                        detected_codec(
                                                                          codec.xz(),
                                                                          extension: "xz",
                                                                        ),
                                                                      )
                                                                    False ->
                                                                      case
                                                                        string.ends_with(
                                                                          lower,
                                                                          ".br",
                                                                        )
                                                                      {
                                                                        True ->
                                                                          Ok(
                                                                            detected_codec(
                                                                              codec.brotli(),
                                                                              extension: "br",
                                                                            ),
                                                                          )
                                                                        False ->
                                                                          case
                                                                            string.ends_with(
                                                                              lower,
                                                                              ".zst",
                                                                            )
                                                                          {
                                                                            True ->
                                                                              Ok(
                                                                                detected_codec(
                                                                                  codec.zstd(),
                                                                                  extension: "zst",
                                                                                ),
                                                                              )
                                                                            False ->
                                                                              Error(
                                                                                error.DetectUnknownFormat(
                                                                                  input: path,
                                                                                ),
                                                                              )
                                                                          }
                                                                      }
                                                                  }
                                                              }
                                                          }
                                                      }
                                                  }
                                              }
                                          }
                                      }
                                  }
                              }
                          }
                      }
                  }
              }
          }
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
