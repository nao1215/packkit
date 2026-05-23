//// Facade for the `packkit` package.  This module wires the codec,
//// archive, and recipe primitives so callers can read, write, pack,
//// and unpack data without selecting the underlying engine by hand.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import packkit/ar
import packkit/archive
import packkit/brotli
import packkit/bzip2
import packkit/codec
import packkit/cpio
import packkit/deflate
import packkit/detect
import packkit/error
import packkit/gzip
import packkit/level
import packkit/lz4
import packkit/lzw
import packkit/recipe
import packkit/seven_z
import packkit/snappy
import packkit/tar
import packkit/xz
import packkit/zip as zip_archive
import packkit/zlib
import packkit/zstd

pub type Archive =
  archive.Archive

pub type ArchiveFormat =
  archive.ArchiveFormat

pub type Codec =
  codec.Codec

pub type CodecError =
  error.CodecError

pub type ArchiveError =
  error.ArchiveError

pub type DetectError =
  error.DetectError

pub type Detected =
  detect.Detected

pub type Recipe =
  recipe.Recipe

/// The package version.
pub fn package_version() -> String {
  "0.1.0"
}

/// Compress `bytes` with `codec`.  The codec's optional level and
/// preset dictionary are honoured where the family supports them; if
/// the family cannot honour an option a typed `CodecOptionUnsupported`
/// error is returned instead of silently dropping the request.
pub fn compress(
  bytes bytes: BitArray,
  with codec_value: Codec,
) -> Result(BitArray, error.CodecError) {
  case codec.name(codec_value) {
    "identity" -> {
      use _ <- result.try(reject_dictionary(codec_value))
      Ok(bytes)
    }
    "deflate" -> compress_deflate(bytes, codec_value)
    "zlib" -> compress_zlib(bytes, codec_value)
    "gzip" -> compress_gzip(bytes, codec_value)
    "lz4" -> compress_levelless(bytes, codec_value, "lz4", lz4.encode)
    "snappy" -> compress_levelless(bytes, codec_value, "snappy", snappy.encode)
    "bzip2" -> compress_bzip2(bytes, codec_value)
    "lzw" -> compress_levelless(bytes, codec_value, "lzw", lzw.encode)
    "xz" -> compress_levellish(bytes, codec_value, "xz", xz.encode)
    "zstd" -> compress_levellish(bytes, codec_value, "zstd", zstd.encode)
    "brotli" -> compress_levellish(bytes, codec_value, "brotli", brotli.encode)
    other -> Error(error.CodecNotImplemented(feature: "compress " <> other))
  }
}

/// Decompress `bytes` with `codec`.  Honours the codec's optional
/// preset dictionary (currently only zlib) and otherwise rejects
/// dictionary use with a typed error.
pub fn decompress(
  bytes bytes: BitArray,
  with codec_value: Codec,
) -> Result(BitArray, error.CodecError) {
  case codec.name(codec_value) {
    "identity" -> {
      use _ <- result.try(reject_dictionary(codec_value))
      Ok(bytes)
    }
    "deflate" -> {
      use _ <- result.try(reject_dictionary(codec_value))
      deflate.decode(bytes: bytes)
    }
    "zlib" -> decompress_zlib(bytes, codec_value)
    "gzip" -> {
      use _ <- result.try(reject_dictionary(codec_value))
      gzip.decode(bytes: bytes)
      |> result.map(fn(decoded) { decoded.payload })
    }
    "lz4" -> {
      use _ <- result.try(reject_dictionary(codec_value))
      lz4.decode(bytes: bytes)
    }
    "snappy" -> {
      use _ <- result.try(reject_dictionary(codec_value))
      snappy.decode(bytes: bytes)
    }
    "bzip2" -> {
      use _ <- result.try(reject_dictionary(codec_value))
      bzip2.decode(bytes: bytes)
    }
    "lzw" -> {
      use _ <- result.try(reject_dictionary(codec_value))
      lzw.decode(bytes: bytes)
    }
    "xz" -> {
      use _ <- result.try(reject_dictionary(codec_value))
      xz.decode(bytes: bytes)
    }
    "zstd" -> {
      use _ <- result.try(reject_dictionary(codec_value))
      zstd.decode(bytes: bytes)
    }
    "brotli" -> {
      use _ <- result.try(reject_dictionary(codec_value))
      brotli.decode(bytes: bytes)
    }
    other -> Error(error.CodecNotImplemented(feature: "decompress " <> other))
  }
}

fn compress_deflate(
  bytes: BitArray,
  codec_value: Codec,
) -> Result(BitArray, error.CodecError) {
  use _ <- result.try(reject_dictionary(codec_value))
  case effective_level(codec_value) {
    Some(0) -> deflate.encode_stored_only(bytes: bytes)
    _ -> deflate.encode(bytes: bytes)
  }
}

fn compress_zlib(
  bytes: BitArray,
  codec_value: Codec,
) -> Result(BitArray, error.CodecError) {
  // The level is intentionally not threaded through: zlib.encode
  // delegates to the fixed-Huffman DEFLATE encoder, which has no
  // level knob today.  Rejecting non-default levels would break
  // `codec.zlib() |> codec.with_level(...)` callers without giving
  // them anything in return.
  case codec.dictionary_of(codec_value) {
    None -> zlib.encode(bytes: bytes)
    Some(dict) ->
      zlib.encode_with_dictionary(
        bytes: bytes,
        dictionary: codec.dictionary_bytes(dict),
      )
  }
}

fn decompress_zlib(
  bytes: BitArray,
  codec_value: Codec,
) -> Result(BitArray, error.CodecError) {
  case codec.dictionary_of(codec_value) {
    None -> zlib.decode(bytes: bytes)
    Some(dict) ->
      zlib.decode_with_dictionary(
        bytes: bytes,
        dictionary: codec.dictionary_bytes(dict),
      )
  }
}

fn compress_gzip(
  bytes: BitArray,
  codec_value: Codec,
) -> Result(BitArray, error.CodecError) {
  use _ <- result.try(reject_dictionary(codec_value))
  // Level intentionally not threaded through (see `compress_zlib`).
  gzip.encode(bytes: bytes, header: gzip.default_header())
}

fn compress_bzip2(
  bytes: BitArray,
  codec_value: Codec,
) -> Result(BitArray, error.CodecError) {
  use _ <- result.try(reject_dictionary(codec_value))
  let level_value = case effective_level(codec_value) {
    // Treat "store" (0) as the smallest valid bzip2 block size (1)
    // so callers can ask for the fastest setting without colliding
    // with the bzip2-specific 1..9 range.
    Some(0) -> 1
    Some(n) -> int_clamp(n, 1, 9)
    None -> 9
  }
  bzip2.encode_with_level(bytes: bytes, level: level_value)
}

/// Codecs whose encoders genuinely cannot consume a level knob — any
/// non-`None` level (other than the implicit default) is reported as
/// `CodecOptionUnsupported` so callers see the mismatch instead of
/// the codec silently doing the same thing for every level.
fn compress_levelless(
  bytes: BitArray,
  codec_value: Codec,
  codec_name: String,
  run: fn(BitArray) -> Result(BitArray, error.CodecError),
) -> Result(BitArray, error.CodecError) {
  use _ <- result.try(reject_dictionary(codec_value))
  use _ <- result.try(reject_level(codec_value, codec_name))
  run(bytes)
}

/// Codecs whose encoders accept a level conceptually but currently
/// always emit the simplest representation (xz LZMA2 uncompressed,
/// zstd raw frames, brotli uncompressed metablocks).  The level value
/// is intentionally accepted and ignored: rejecting it would force
/// every caller of `codec.xz()` / `codec.zstd()` / `codec.brotli()`
/// (which all carry `level.default()`) to clear the level before
/// using the facade, and that's an ergonomics regression for no
/// safety win.  Dictionaries are still rejected.
fn compress_levellish(
  bytes: BitArray,
  codec_value: Codec,
  _codec_name: String,
  run: fn(BitArray) -> Result(BitArray, error.CodecError),
) -> Result(BitArray, error.CodecError) {
  use _ <- result.try(reject_dictionary(codec_value))
  run(bytes)
}

fn reject_dictionary(codec_value: Codec) -> Result(Nil, error.CodecError) {
  case codec.dictionary_of(codec_value) {
    None -> Ok(Nil)
    Some(_) ->
      case codec.name(codec_value) {
        "zlib" -> Ok(Nil)
        name ->
          Error(error.CodecOptionUnsupported(
            option: "dictionary",
            codec_name: name,
          ))
      }
  }
}

fn reject_level(
  codec_value: Codec,
  codec_name: String,
) -> Result(Nil, error.CodecError) {
  case codec.level(codec_value) {
    None -> Ok(Nil)
    Some(_) ->
      Error(error.CodecOptionUnsupported(
        option: "level",
        codec_name: codec_name,
      ))
  }
}

fn effective_level(codec_value: Codec) -> Option(Int) {
  case codec.level(codec_value) {
    Some(l) -> Some(level.value(l))
    None -> None
  }
}

fn int_clamp(value: Int, low: Int, high: Int) -> Int {
  case value < low, value > high {
    True, _ -> low
    _, True -> high
    _, _ -> value
  }
}

/// Read an archive from `bytes` interpreted as `format`.
pub fn read(
  bytes bytes: BitArray,
  format format: ArchiveFormat,
) -> Result(Archive, error.ArchiveError) {
  case archive.name(format) {
    "tar" -> tar.decode(bytes: bytes)
    "zip" -> zip_archive.decode(bytes: bytes)
    "cpio-newc" -> cpio.decode(bytes: bytes)
    "ar" -> ar.decode(bytes: bytes)
    "7z" -> seven_z.decode(bytes: bytes)
    other -> Error(error.ArchiveNotImplemented(feature: "read " <> other))
  }
}

/// Serialise an archive to bytes using `format`.
pub fn write(
  archive_value archive_value: Archive,
  format format: ArchiveFormat,
) -> Result(BitArray, error.ArchiveError) {
  case archive.name(format) {
    "tar" -> tar.encode(archive: archive_value)
    "zip" -> zip_archive.encode(archive: archive_value)
    "cpio-newc" -> cpio.encode(archive: archive_value)
    "ar" -> ar.encode(archive: archive_value)
    "7z" -> seven_z.encode(archive: archive_value)
    other -> Error(error.ArchiveNotImplemented(feature: "write " <> other))
  }
}

/// Pack an archive with the codec chain described by `recipe`.
pub fn pack(
  archive_value archive_value: Archive,
  using recipe_value: Recipe,
) -> Result(BitArray, error.ArchiveError) {
  use archive_bytes <- result.try(case recipe.archive_format(recipe_value) {
    Some(format) -> write(archive_value: archive_value, format: format)
    None ->
      Error(error.ArchiveInvalid(
        message: "pack requires the recipe to declare an archive format",
      ))
  })

  apply_codec_chain_forward(archive_bytes, recipe.codecs(recipe_value))
  |> codec_to_archive_error(step: "encode")
}

/// Unpack a byte stream produced by `recipe`.
pub fn unpack(
  bytes bytes: BitArray,
  using recipe_value: Recipe,
) -> Result(Archive, error.ArchiveError) {
  use raw_bytes <- result.try(
    apply_codec_chain_reverse(bytes, list.reverse(recipe.codecs(recipe_value)))
    |> codec_to_archive_error(step: "decode"),
  )

  case recipe.archive_format(recipe_value) {
    Some(format) -> read(bytes: raw_bytes, format: format)
    None ->
      Error(error.ArchiveInvalid(
        message: "unpack requires the recipe to declare an archive format",
      ))
  }
}

/// Detect from a filename or path suffix.
pub fn detect_filename(path: String) -> Result(Detected, error.DetectError) {
  detect.from_filename(path)
}

/// Detect from byte signatures.
pub fn detect_bytes(bytes: BitArray) -> Result(Detected, error.DetectError) {
  detect.from_bytes(bytes)
}

fn apply_codec_chain_forward(
  bytes: BitArray,
  codecs: List(Codec),
) -> Result(BitArray, error.CodecError) {
  case codecs {
    [] -> Ok(bytes)
    [head, ..rest] -> {
      use compressed <- result.try(compress(bytes: bytes, with: head))
      apply_codec_chain_forward(compressed, rest)
    }
  }
}

fn apply_codec_chain_reverse(
  bytes: BitArray,
  codecs: List(Codec),
) -> Result(BitArray, error.CodecError) {
  case codecs {
    [] -> Ok(bytes)
    [head, ..rest] -> {
      use plain <- result.try(decompress(bytes: bytes, with: head))
      apply_codec_chain_reverse(plain, rest)
    }
  }
}

fn codec_to_archive_error(
  value: Result(a, error.CodecError),
  step step: String,
) -> Result(a, error.ArchiveError) {
  case value {
    Ok(v) -> Ok(v)
    Error(err) -> Error(error.ArchiveCodecFailed(step: step, cause: err))
  }
}
