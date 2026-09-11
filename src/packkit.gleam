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
  "0.3.0"
}

/// Compress `bytes` with `codec`.  The codec's optional level and
/// preset dictionary are honoured where the family supports them; if
/// the family cannot honour an option a typed `CodecOptionUnsupported`
/// error is returned instead of silently dropping the request.
pub fn compress(
  bytes bytes: BitArray,
  with codec_value: Codec,
) -> Result(BitArray, error.CodecError) {
  case codec.kind(codec_value) {
    codec.Identity -> {
      use _ <- result.try(reject_dictionary(codec_value))
      use _ <- result.try(reject_non_default_level(codec_value, "identity"))
      Ok(bytes)
    }
    codec.Deflate -> compress_deflate(bytes, codec_value)
    codec.Zlib -> compress_zlib(bytes, codec_value)
    codec.Gzip -> compress_gzip(bytes, codec_value)
    codec.Lz4 -> compress_levelless(bytes, codec_value, "lz4", lz4.encode)
    codec.Snappy ->
      compress_levelless(bytes, codec_value, "snappy", snappy.encode)
    codec.Bzip2 -> compress_bzip2(bytes, codec_value)
    codec.Lzw -> compress_levelless(bytes, codec_value, "lzw", lzw.encode)
    codec.Xz -> compress_fixed_level(bytes, codec_value, "xz", xz.encode)
    codec.Zstd -> compress_fixed_level(bytes, codec_value, "zstd", zstd.encode)
    codec.Brotli ->
      compress_fixed_level(bytes, codec_value, "brotli", brotli.encode)
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
  case codec.kind(codec_value) {
    codec.Identity -> {
      use _ <- result.try(reject_dictionary(codec_value))
      use _ <- result.try(reject_non_default_level(codec_value, "identity"))
      enforce_input_limit(bytes, limits)
      |> result.map(fn(_) { bytes })
    }
    codec.Deflate -> {
      use _ <- result.try(reject_dictionary(codec_value))
      deflate.decode_with_limits(bytes: bytes, limits: limits)
    }
    codec.Zlib -> decompress_zlib(bytes, codec_value, limits)
    codec.Gzip -> {
      use _ <- result.try(reject_dictionary(codec_value))
      gzip.decode_with_limits(bytes: bytes, limits: limits)
      |> result.map(fn(decoded) { decoded.payload })
    }
    codec.Lz4 -> {
      use _ <- result.try(reject_dictionary(codec_value))
      lz4.decode_with_limits(bytes: bytes, limits: limits)
    }
    codec.Snappy -> {
      use _ <- result.try(reject_dictionary(codec_value))
      snappy.decode_with_limits(bytes: bytes, limits: limits)
    }
    codec.Bzip2 -> {
      use _ <- result.try(reject_dictionary(codec_value))
      bzip2.decode_with_limits(bytes: bytes, limits: limits)
    }
    codec.Lzw -> {
      use _ <- result.try(reject_dictionary(codec_value))
      lzw.decode_with_limits(bytes: bytes, limits: limits)
    }
    codec.Xz -> {
      use _ <- result.try(reject_dictionary(codec_value))
      xz.decode_with_limits(bytes: bytes, limits: limits)
    }
    codec.Zstd -> {
      use _ <- result.try(reject_dictionary(codec_value))
      zstd.decode_with_limits(bytes: bytes, limits: limits)
    }
    codec.Brotli -> {
      use _ <- result.try(reject_dictionary(codec_value))
      brotli.decode_with_limits(bytes: bytes, limits: limits)
    }
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
  // DEFLATE honours exactly two settings today: level 0 (`store`) and
  // the implicit default (fixed-Huffman LZ77).  Anything else would be
  // silently coerced, so reject it.
  case effective_level(codec_value) {
    None -> deflate.encode(bytes: bytes)
    Some(0) -> deflate.encode_stored_only(bytes: bytes)
    Some(n) ->
      case n == default_level_value() {
        True -> deflate.encode(bytes: bytes)
        False ->
          Error(error.CodecOptionUnsupported(
            option: "level",
            codec_name: "deflate",
          ))
      }
  }
}

fn compress_zlib(
  bytes: BitArray,
  codec_value: Codec,
) -> Result(BitArray, error.CodecError) {
  // zlib.encode delegates to the fixed-Huffman DEFLATE encoder, which
  // has no level knob today.  Accept only the implicit default level
  // so callers can't pass `with_level(level.best())` and silently get
  // the same bytes as `with_level(level.fast())`.
  use _ <- result.try(reject_non_default_level(codec_value, "zlib"))
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
  // gzip.encode shares the zlib code path's lack of a level knob, so
  // we accept only the implicit default level for the same reason.
  use _ <- result.try(reject_non_default_level(codec_value, "gzip"))
  gzip.encode(bytes: bytes)
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
/// zstd raw frames, brotli uncompressed metablocks).  We accept the
/// implicit default level (so the smart constructor still works) but
/// reject any caller-supplied non-default level so it's never
/// silently dropped.  Dictionaries are still rejected.
fn compress_fixed_level(
  bytes: BitArray,
  codec_value: Codec,
  codec_name: String,
  run: fn(BitArray) -> Result(BitArray, error.CodecError),
) -> Result(BitArray, error.CodecError) {
  use _ <- result.try(reject_dictionary(codec_value))
  use _ <- result.try(reject_non_default_level(codec_value, codec_name))
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

/// Accepts the implicit default level, rejects anything else with
/// `CodecOptionUnsupported`.  Used by codecs whose encoders share a
/// single fixed strategy, so non-default levels would be silently
/// dropped if accepted.
fn reject_non_default_level(
  codec_value: Codec,
  codec_name: String,
) -> Result(Nil, error.CodecError) {
  case codec.level(codec_value) {
    None -> Ok(Nil)
    Some(l) ->
      case level.value(l) == default_level_value() {
        True -> Ok(Nil)
        False ->
          Error(error.CodecOptionUnsupported(
            option: "level",
            codec_name: codec_name,
          ))
      }
  }
}

fn default_level_value() -> Int {
  level.value(level.default())
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
  case archive.kind(format) {
    archive.Tar -> tar.decode_with_limits(bytes: bytes, limits: limits)
    archive.Zip -> zip_archive.decode_with_limits(bytes: bytes, limits: limits)
    archive.CpioNewc -> cpio.decode_with_limits(bytes: bytes, limits: limits)
    archive.Ar -> ar.decode_with_limits(bytes: bytes, limits: limits)
    archive.SevenZ -> seven_z.decode_with_limits(bytes: bytes, limits: limits)
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
  case archive.kind(format) {
    archive.Tar -> tar.encode(archive: archive_value)
    archive.Zip -> zip_archive.encode(archive: archive_value)
    archive.CpioNewc -> cpio.encode(archive: archive_value)
    archive.Ar -> ar.encode(archive: archive_value)
    archive.SevenZ -> seven_z.encode(archive: archive_value)
  }
}

fn ensure_archive_format_matches(
  archive_value: Archive,
  requested: ArchiveFormat,
) -> Result(Nil, error.ArchiveError) {
  let archive_kind = archive.kind(archive.format(archive_value))
  let requested_kind = archive.kind(requested)
  case archive_kind == requested_kind {
    True -> Ok(Nil)
    False ->
      Error(error.ArchiveFormatMismatch(
        archive: archive.name(archive.format(archive_value)),
        requested: archive.name(requested),
      ))
  }
}

/// Pack an archive with the codec chain described by `recipe`.
pub fn pack(
  archive_value archive_value: Archive,
  using recipe_value: Recipe,
) -> Result(BitArray, error.ArchiveError) {
  use archive_bytes <- result.try(write(
    archive_value: archive_value,
    format: recipe.archive_format(recipe_value),
  ))

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

  read_with_limits(
    bytes: raw_bytes,
    format: recipe.archive_format(recipe_value),
    limits: limits,
  )
}

/// Detect from a filename or path suffix.
pub fn detect_filename(path: String) -> Result(Detected, error.DetectError) {
  detect.from_filename(path)
}

/// Detect from byte signatures.
pub fn detect_bytes(bytes: BitArray) -> Result(Detected, error.DetectError) {
  detect.from_bytes(bytes)
}

/// Detect via filename first, then fall back to magic-byte detection
/// on the supplied content.  Re-exports
/// `packkit/detect.from_path_or_bytes` from the top-level facade so
/// most CLI integrations only need to import `packkit`.
pub fn detect_path_or_bytes(
  path path: String,
  bytes bytes: BitArray,
) -> Result(Detected, error.DetectError) {
  detect.from_path_or_bytes(path: path, bytes: bytes)
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
