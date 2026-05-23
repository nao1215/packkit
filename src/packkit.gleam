//// Facade for the `packkit` package.  This module wires the codec,
//// archive, and recipe primitives so callers can read, write, pack,
//// and unpack data without selecting the underlying engine by hand.

import gleam/bit_array
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
import packkit/limit
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

pub type Limits =
  limit.Limits

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

/// Decompress `bytes` with `codec` using the default limits.  Honours
/// the codec's optional preset dictionary (currently only zlib) and
/// otherwise rejects dictionary use with a typed error.
pub fn decompress(
  bytes bytes: BitArray,
  with codec_value: Codec,
) -> Result(BitArray, error.CodecError) {
  decompress_with_limits(
    bytes: bytes,
    with: codec_value,
    limits: limit.default(),
  )
}

/// Decompress `bytes` with `codec`, threading the supplied `Limits`
/// value through to the underlying codec's `decode_with_limits`
/// entrypoint.  Codecs without an explicit limits hook receive their
/// own family-specific defaults; today every byte-to-byte codec we
/// support honours `Limits`.
pub fn decompress_with_limits(
  bytes bytes: BitArray,
  with codec_value: Codec,
  limits limits: Limits,
) -> Result(BitArray, error.CodecError) {
  case codec.name(codec_value) {
    "identity" -> {
      use _ <- result.try(reject_dictionary(codec_value))
      enforce_input_limit(bytes, limits)
      |> result.map(fn(_) { bytes })
    }
    "deflate" -> {
      use _ <- result.try(reject_dictionary(codec_value))
      deflate.decode_with_limits(bytes: bytes, limits: limits)
    }
    "zlib" -> decompress_zlib(bytes, codec_value, limits)
    "gzip" -> {
      use _ <- result.try(reject_dictionary(codec_value))
      gzip.decode_with_limits(bytes: bytes, limits: limits)
      |> result.map(fn(decoded) { decoded.payload })
    }
    "lz4" -> {
      use _ <- result.try(reject_dictionary(codec_value))
      lz4.decode_with_limits(bytes: bytes, limits: limits)
    }
    "snappy" -> {
      use _ <- result.try(reject_dictionary(codec_value))
      snappy.decode_with_limits(bytes: bytes, limits: limits)
    }
    "bzip2" -> {
      use _ <- result.try(reject_dictionary(codec_value))
      bzip2.decode_with_limits(bytes: bytes, limits: limits)
    }
    "lzw" -> {
      use _ <- result.try(reject_dictionary(codec_value))
      lzw.decode_with_limits(bytes: bytes, limits: limits)
    }
    "xz" -> {
      use _ <- result.try(reject_dictionary(codec_value))
      xz.decode_with_limits(bytes: bytes, limits: limits)
    }
    "zstd" -> {
      use _ <- result.try(reject_dictionary(codec_value))
      zstd.decode_with_limits(bytes: bytes, limits: limits)
    }
    "brotli" -> {
      use _ <- result.try(reject_dictionary(codec_value))
      brotli.decode_with_limits(bytes: bytes, limits: limits)
    }
    other -> Error(error.CodecNotImplemented(feature: "decompress " <> other))
  }
}

fn enforce_input_limit(
  bytes: BitArray,
  limits: Limits,
) -> Result(Nil, error.CodecError) {
  let size = bit_array.byte_size(bytes)
  case size > limit.max_input_bytes(limits) {
    True ->
      Error(error.CodecLimitExceeded(limit: "max_input_bytes", actual: size))
    False -> Ok(Nil)
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
  limits: Limits,
) -> Result(BitArray, error.CodecError) {
  case codec.dictionary_of(codec_value) {
    None -> zlib.decode_with_limits(bytes: bytes, limits: limits)
    Some(dict) ->
      zlib.decode_with_dictionary_and_limits(
        bytes: bytes,
        dictionary: codec.dictionary_bytes(dict),
        limits: limits,
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

/// Read an archive from `bytes` interpreted as `format` using the
/// default resource limits.
pub fn read(
  bytes bytes: BitArray,
  format format: ArchiveFormat,
) -> Result(Archive, error.ArchiveError) {
  read_with_limits(bytes: bytes, format: format, limits: limit.default())
}

/// Read an archive while threading the supplied `Limits` through to
/// the underlying archive decoder.  Each family enforces the subset of
/// limits that applies to it (input size, member count, name length,
/// entry depth).
pub fn read_with_limits(
  bytes bytes: BitArray,
  format format: ArchiveFormat,
  limits limits: Limits,
) -> Result(Archive, error.ArchiveError) {
  case archive.name(format) {
    "tar" -> tar.decode_with_limits(bytes: bytes, limits: limits)
    "zip" -> zip_archive.decode_with_limits(bytes: bytes, limits: limits)
    "cpio-newc" -> cpio.decode_with_limits(bytes: bytes, limits: limits)
    "ar" -> ar.decode_with_limits(bytes: bytes, limits: limits)
    "7z" -> seven_z.decode_with_limits(bytes: bytes, limits: limits)
    other -> Error(error.ArchiveNotImplemented(feature: "read " <> other))
  }
}

/// Serialise an archive to bytes using `format`.  The supplied
/// `format` must match the format tag the `Archive` was constructed
/// with — `Archive` is bound to one format at construction time, and
/// pretending it is a different format would silently corrupt the
/// output.  Mismatches surface as `ArchiveFormatMismatch`.
pub fn write(
  archive_value archive_value: Archive,
  format format: ArchiveFormat,
) -> Result(BitArray, error.ArchiveError) {
  use _ <- result.try(ensure_archive_format_matches(archive_value, format))
  case archive.name(format) {
    "tar" -> tar.encode(archive: archive_value)
    "zip" -> zip_archive.encode(archive: archive_value)
    "cpio-newc" -> cpio.encode(archive: archive_value)
    "ar" -> ar.encode(archive: archive_value)
    "7z" -> seven_z.encode(archive: archive_value)
    other -> Error(error.ArchiveNotImplemented(feature: "write " <> other))
  }
}

fn ensure_archive_format_matches(
  archive_value: Archive,
  requested: ArchiveFormat,
) -> Result(Nil, error.ArchiveError) {
  let archive_name = archive.name(archive.format(archive_value))
  let requested_name = archive.name(requested)
  case archive_name == requested_name {
    True -> Ok(Nil)
    False ->
      Error(error.ArchiveFormatMismatch(
        archive: archive_name,
        requested: requested_name,
      ))
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

/// Unpack a byte stream produced by `recipe` using the default
/// resource limits.
pub fn unpack(
  bytes bytes: BitArray,
  using recipe_value: Recipe,
) -> Result(Archive, error.ArchiveError) {
  unpack_with_limits(bytes: bytes, using: recipe_value, limits: limit.default())
}

/// Unpack a byte stream produced by `recipe`, threading the supplied
/// `Limits` through both the codec chain and the underlying archive
/// decoder.
pub fn unpack_with_limits(
  bytes bytes: BitArray,
  using recipe_value: Recipe,
  limits limits: Limits,
) -> Result(Archive, error.ArchiveError) {
  use raw_bytes <- result.try(
    apply_codec_chain_reverse(
      bytes,
      list.reverse(recipe.codecs(recipe_value)),
      limits,
    )
    |> codec_to_archive_error(step: "decode"),
  )

  case recipe.archive_format(recipe_value) {
    Some(format) ->
      read_with_limits(bytes: raw_bytes, format: format, limits: limits)
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
  limits: Limits,
) -> Result(BitArray, error.CodecError) {
  case codecs {
    [] -> Ok(bytes)
    [head, ..rest] -> {
      use plain <- result.try(decompress_with_limits(
        bytes: bytes,
        with: head,
        limits: limits,
      ))
      apply_codec_chain_reverse(plain, rest, limits)
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
