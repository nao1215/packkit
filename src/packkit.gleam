//// Facade for the `packkit` package.  This module wires the codec,
//// archive, and recipe primitives so callers can read, write, pack,
//// and unpack data without selecting the underlying engine by hand.

import gleam/list
import gleam/option.{None, Some}
import gleam/result
import packkit/ar
import packkit/archive
import packkit/bzip2
import packkit/codec
import packkit/cpio
import packkit/deflate
import packkit/detect
import packkit/error
import packkit/gzip
import packkit/lz4
import packkit/lzw
import packkit/recipe
import packkit/seven_z
import packkit/snappy
import packkit/tar
import packkit/zip as zip_archive
import packkit/zlib

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

/// Compress `bytes` with `codec`.
pub fn compress(
  bytes bytes: BitArray,
  with codec_value: Codec,
) -> Result(BitArray, error.CodecError) {
  case codec.name(codec_value) {
    "identity" -> Ok(bytes)
    "deflate" -> deflate.encode(bytes: bytes)
    "zlib" -> zlib.encode(bytes: bytes)
    "gzip" -> gzip.encode(bytes: bytes, header: gzip.default_header())
    "lz4-frame" -> lz4.encode(bytes: bytes)
    "snappy-frame" -> snappy.encode(bytes: bytes)
    "bzip2" -> bzip2.encode(bytes: bytes)
    "lzw" -> lzw.encode(bytes: bytes)
    other -> Error(error.CodecNotImplemented(feature: "compress " <> other))
  }
}

/// Decompress `bytes` with `codec`.
pub fn decompress(
  bytes bytes: BitArray,
  with codec_value: Codec,
) -> Result(BitArray, error.CodecError) {
  case codec.name(codec_value) {
    "identity" -> Ok(bytes)
    "deflate" -> deflate.decode(bytes: bytes)
    "zlib" -> zlib.decode(bytes: bytes)
    "gzip" ->
      gzip.decode(bytes: bytes)
      |> result.map(fn(decoded) { decoded.payload })
    "lz4-frame" -> lz4.decode(bytes: bytes)
    "snappy-frame" -> snappy.decode(bytes: bytes)
    "bzip2" -> bzip2.decode(bytes: bytes)
    "lzw" -> lzw.decode(bytes: bytes)
    other -> Error(error.CodecNotImplemented(feature: "decompress " <> other))
  }
}

/// Read an archive from `bytes` interpreted as `format`.
pub fn read(
  bytes bytes: BitArray,
  format format: ArchiveFormat,
) -> Result(Archive, error.ArchiveError) {
  case archive.format_name(format) {
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
  case archive.format_name(format) {
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
  |> codec_to_archive_error
}

/// Unpack a byte stream produced by `recipe`.
pub fn unpack(
  bytes bytes: BitArray,
  using recipe_value: Recipe,
) -> Result(Archive, error.ArchiveError) {
  use raw_bytes <- result.try(
    apply_codec_chain_reverse(bytes, list.reverse(recipe.codecs(recipe_value)))
    |> codec_to_archive_error,
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
) -> Result(a, error.ArchiveError) {
  case value {
    Ok(v) -> Ok(v)
    Error(err) ->
      Error(error.ArchiveInvalid(
        message: "codec error during recipe step: " <> codec_error_message(err),
      ))
  }
}

fn codec_error_message(err: error.CodecError) -> String {
  case err {
    error.CodecUnsupported(name) -> "unsupported codec " <> name
    error.CodecInvalidData(message) -> "invalid data: " <> message
    error.CodecLimitExceeded(limit, _) -> "limit exceeded: " <> limit
    error.CodecDictionaryRequired(name) ->
      "codec " <> name <> " requires a preset dictionary"
    error.CodecNotImplemented(feature) -> "not implemented: " <> feature
  }
}
