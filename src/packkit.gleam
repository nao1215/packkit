//// Compress and decompress bytes, read and write archives, and detect a
//// format from a file name or the first bytes of a file.
////
//// ```gleam
//// import gleam/option.{None}
//// import packkit
//// import packkit/archive.{Archive, File, Tar}
//// import packkit/codec.{Gzip}
////
//// let backup =
////   Archive(
////     format: Tar,
////     entries: [archive.new_entry(path: "hello.txt", kind: File(<<"hi":utf8>>))],
////     comment: None,
////   )
//// let recipe = packkit.Recipe(format: Tar, codecs: [Gzip])
//// let assert Ok(bytes) = packkit.pack(backup, using: recipe)
//// let assert Ok(restored) = packkit.unpack(bytes, using: recipe)
//// ```

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import packkit/archive.{
  type Archive, type ArchiveFormat, Ar, CodecFailed, Cpio, FormatMismatch,
  SevenZ, Tar, Zip,
}
import packkit/codec.{
  type Codec, Brotli, Bzip2, Deflate, Gzip, Identity, LimitExceeded, Lz4, Lzw,
  Snappy, Xz, Zlib, Zstd,
}
import packkit/gzip
import packkit/internal/ar
import packkit/internal/brotli
import packkit/internal/bzip2
import packkit/internal/cpio
import packkit/internal/deflate
import packkit/internal/entry
import packkit/internal/lz4
import packkit/internal/lzw
import packkit/internal/snappy
import packkit/internal/tar
import packkit/internal/xz
import packkit/internal/zlib
import packkit/internal/zstd
import packkit/limit.{type Limits}
import packkit/seven_z
import packkit/zip

/// An archive format and the codecs wrapped around it, listed from the
/// inside out. `Recipe(format: Tar, codecs: [Gzip])` is a `.tar.gz`.
pub type Recipe {
  Recipe(format: ArchiveFormat, codecs: List(Codec))
}

/// What `detect_filename`, `detect_bytes` and `detect` found.
pub type Detected {
  /// A single compressed stream, such as `.gz` or `.zst`.
  Compressed(codec: Codec)
  /// An archive, possibly compressed, such as `.tar.gz` or `.zip`.
  Archived(recipe: Recipe)
}

// Codecs ----------------------------------------------------------------

/// Compresses `bytes` with `codec`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(compressed) = compress(<<"hello":utf8>>, with: Gzip)
/// decompress(compressed, with: Gzip)
/// // -> Ok(<<"hello":utf8>>)
/// ```
///
pub fn compress(
  bytes: BitArray,
  with codec: Codec,
) -> Result(BitArray, codec.CodecError) {
  case codec {
    Identity -> Ok(bytes)
    Deflate -> deflate.encode(bytes:)
    Zlib -> zlib.encode(bytes:)
    Gzip -> Ok(gzip.encode_without_header(bytes))
    Lz4 -> lz4.encode(bytes:)
    Snappy -> snappy.encode(bytes:)
    Bzip2 -> bzip2.encode(bytes:)
    Lzw -> lzw.encode(bytes:)
    Xz -> xz.encode(bytes:)
    Zstd -> zstd.encode(bytes:)
    Brotli -> brotli.encode(bytes:)
  }
}

/// Decompresses `bytes` with `codec` under the default `Limits`.
///
/// Returns `InvalidData` when the bytes are not a valid stream and
/// `LimitExceeded` when the input or output is larger than the limits.
///
/// ## Examples
///
/// ```gleam
/// decompress(<<"not gzip":utf8>>, with: Gzip)
/// // -> Error(InvalidData("gzip header truncated"))
/// ```
///
pub fn decompress(
  bytes: BitArray,
  with codec: Codec,
) -> Result(BitArray, codec.CodecError) {
  decompress_with_limits(bytes, with: codec, limits: limit.default())
}

/// Decompresses `bytes` with `codec` under `limits`.
///
pub fn decompress_with_limits(
  bytes: BitArray,
  with codec: Codec,
  limits limits: Limits,
) -> Result(BitArray, codec.CodecError) {
  case codec {
    Identity -> {
      let size = bit_array.byte_size(bytes)
      use <- bool.guard(
        when: size > limits.max_input_bytes,
        return: Error(LimitExceeded(limit: "max_input_bytes", actual: size)),
      )
      use <- bool.guard(
        when: size > limits.max_output_bytes,
        return: Error(LimitExceeded(limit: "max_output_bytes", actual: size)),
      )
      Ok(bytes)
    }
    Deflate -> deflate.decode_with_limits(bytes:, limits:)
    Zlib -> zlib.decode_with_limits(bytes:, limits:)
    Gzip ->
      gzip.decode(bytes, limits:) |> result.map(fn(decoded) { decoded.payload })
    Lz4 -> lz4.decode_with_limits(bytes:, limits:)
    Snappy -> snappy.decode_with_limits(bytes:, limits:)
    Bzip2 -> bzip2.decode_with_limits(bytes:, limits:)
    Lzw -> lzw.decode_with_limits(bytes:, limits:)
    Xz -> xz.decode_with_limits(bytes:, limits:)
    Zstd -> zstd.decode_with_limits(bytes:, limits:)
    Brotli -> brotli.decode_with_limits(bytes:, limits:)
  }
}

// Archives --------------------------------------------------------------

/// Reads an archive of `format` from `bytes` under the default `Limits`.
///
/// Entries whose path is absolute, contains `..` or is otherwise unsafe
/// to extract are rejected with `EntryRejected`.
///
pub fn read(
  bytes: BitArray,
  format format: ArchiveFormat,
) -> Result(Archive, archive.ArchiveError) {
  read_with_limits(bytes, format:, limits: limit.default())
}

/// Reads an archive of `format` from `bytes` under `limits`.
///
pub fn read_with_limits(
  bytes: BitArray,
  format format: ArchiveFormat,
  limits limits: Limits,
) -> Result(Archive, archive.ArchiveError) {
  case format {
    Tar -> tar.decode_with_limits(bytes:, limits:)
    Zip -> zip.decode(bytes:, limits:)
    Cpio -> cpio.decode_with_limits(bytes:, limits:)
    Ar -> ar.decode_with_limits(bytes:, limits:)
    SevenZ -> seven_z.decode(bytes:, limits:)
  }
}

/// Writes `archive` in its own format. ZIP entries are stored without
/// compression and 7z uses LZMA; use `packkit/zip` or `packkit/seven_z`
/// to pick another method.
///
/// Returns `EntryRejected` for an entry whose path is empty, absolute,
/// contains `.`, `..`, an empty segment, a backslash or a NUL byte, and
/// for a negative mode, owner id or modification time. Returns
/// `FieldOverflow` when a value is too large for the format and
/// `CommentUnsupported` when the format has no place for the comment.
///
/// ## Examples
///
/// ```gleam
/// let unsafe = archive.new_entry(path: "../etc/passwd", kind: File(<<>>))
/// write(Archive(format: Tar, entries: [unsafe], comment: None))
/// // -> Error(EntryRejected(path: "../etc/passwd", reason: "path traversal"))
/// ```
///
pub fn write(archive: Archive) -> Result(BitArray, archive.ArchiveError) {
  use _ <- result.try(entry.validate_all(archive.entries))
  case archive.format {
    Tar -> tar.encode(archive:)
    Zip -> zip.encode(archive, method: zip.Store)
    Cpio -> cpio.encode(archive:)
    Ar -> ar.encode(archive:)
    SevenZ ->
      seven_z.encode(
        archive,
        method: seven_z.Lzma,
        encryption: seven_z.Unencrypted,
      )
  }
}

/// Writes `archive` and compresses it with the codecs of `recipe`, from
/// the inside out.
///
/// Returns `FormatMismatch` when the recipe's format is not the
/// archive's format, and `CodecFailed` when a codec fails.
///
pub fn pack(
  archive: Archive,
  using recipe: Recipe,
) -> Result(BitArray, archive.ArchiveError) {
  use <- bool.guard(
    when: archive.format != recipe.format,
    return: Error(FormatMismatch(
      archive: archive.format,
      requested: recipe.format,
    )),
  )
  use bytes <- result.try(write(archive))
  list.try_fold(recipe.codecs, bytes, fn(bytes, outer) {
    compress(bytes, with: outer)
  })
  |> result.map_error(CodecFailed(step: "encode", cause: _))
}

/// Decompresses `bytes` with the codecs of `recipe`, from the outside in,
/// and reads the archive under the default `Limits`.
///
pub fn unpack(
  bytes: BitArray,
  using recipe: Recipe,
) -> Result(Archive, archive.ArchiveError) {
  unpack_with_limits(bytes, using: recipe, limits: limit.default())
}

/// Decompresses `bytes` with the codecs of `recipe` and reads the archive
/// under `limits`. Each codec and the archive reader get the same limits.
///
pub fn unpack_with_limits(
  bytes: BitArray,
  using recipe: Recipe,
  limits limits: Limits,
) -> Result(Archive, archive.ArchiveError) {
  use plain <- result.try(
    list.reverse(recipe.codecs)
    |> list.try_fold(bytes, fn(bytes, outer) {
      decompress_with_limits(bytes, with: outer, limits:)
    })
    |> result.map_error(CodecFailed(step: "decode", cause: _)),
  )
  read_with_limits(plain, format: recipe.format, limits:)
}

// Detection -------------------------------------------------------------

/// Detects a format from the end of a file name, ignoring case. Compound
/// extensions win, so `backup.tar.gz` is a gzip-compressed tar archive
/// and not a plain gzip stream.
///
/// ## Examples
///
/// ```gleam
/// detect_filename("backup.tar.gz")
/// // -> Ok(Archived(Recipe(format: Tar, codecs: [Gzip])))
/// detect_filename("notes.txt")
/// // -> Error(Nil)
/// ```
///
pub fn detect_filename(path: String) -> Result(Detected, Nil) {
  let path = string.lowercase(path)
  filename_rules()
  |> list.find(fn(rule) {
    list.any(rule.0, fn(suffix) { string.ends_with(path, suffix) })
  })
  |> result.map(fn(rule) { rule.1 })
}

fn filename_rules() -> List(#(List(String), Detected)) {
  [
    #([".tar.gz", ".tgz"], tar_with(Gzip)),
    #([".tar.zlib"], tar_with(Zlib)),
    #([".tar.lz4"], tar_with(Lz4)),
    #([".tar.sz", ".tar.snappy"], tar_with(Snappy)),
    #([".tar.bz2"], tar_with(Bzip2)),
    #([".tar.xz"], tar_with(Xz)),
    #([".tar.zst"], tar_with(Zstd)),
    #([".tar.br"], tar_with(Brotli)),
    #([".tar.z", ".taz"], tar_with(Lzw)),
    #([".cpio.gz"], cpio_with(Gzip)),
    #([".cpio.bz2"], cpio_with(Bzip2)),
    #([".cpio.xz"], cpio_with(Xz)),
    #([".cpio.zst"], cpio_with(Zstd)),
    #([".tar"], archived(Tar)),
    #([".zip"], archived(Zip)),
    #([".7z"], archived(SevenZ)),
    #([".cpio"], archived(Cpio)),
    #([".ar", ".a"], archived(Ar)),
    #([".gz"], Compressed(Gzip)),
    #([".zlib"], Compressed(Zlib)),
    #([".deflate", ".dfl"], Compressed(Deflate)),
    #([".lz4"], Compressed(Lz4)),
    #([".sz", ".snappy"], Compressed(Snappy)),
    #([".bz2"], Compressed(Bzip2)),
    #([".xz"], Compressed(Xz)),
    #([".br"], Compressed(Brotli)),
    #([".zst"], Compressed(Zstd)),
    #([".z"], Compressed(Lzw)),
  ]
}

fn tar_with(outer: Codec) -> Detected {
  Archived(Recipe(format: Tar, codecs: [outer]))
}

fn cpio_with(outer: Codec) -> Detected {
  Archived(Recipe(format: Cpio, codecs: [outer]))
}

fn archived(format: ArchiveFormat) -> Detected {
  Archived(Recipe(format:, codecs: []))
}

/// Detects a format from the first bytes of a file. 512 bytes are enough
/// for every format.
///
/// A gzip, xz or other compressed stream is reported as `Compressed`
/// even when it holds a tar archive, because the bytes do not say what
/// is inside. Raw DEFLATE and Brotli have no signature and are never
/// detected.
///
/// ## Examples
///
/// ```gleam
/// detect_bytes(<<0x1F, 0x8B, 0x08, 0x00>>)
/// // -> Ok(Compressed(Gzip))
/// detect_bytes(<<"plain text":utf8>>)
/// // -> Error(Nil)
/// ```
///
pub fn detect_bytes(bytes: BitArray) -> Result(Detected, Nil) {
  case bytes {
    <<0x1F, 0x8B, 0x08, _:bytes>> -> Ok(Compressed(Gzip))
    <<0x50, 0x4B, 0x03, 0x04, _:bytes>> | <<0x50, 0x4B, 0x05, 0x06, _:bytes>> ->
      Ok(archived(Zip))
    <<0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, _:bytes>> -> Ok(archived(SevenZ))
    <<0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00, _:bytes>> -> Ok(Compressed(Xz))
    <<0x28, 0xB5, 0x2F, 0xFD, _:bytes>> -> Ok(Compressed(Zstd))
    // A zstd skippable frame, magic 0x184D2A50 to 0x184D2A5F.
    <<low, 0x2A, 0x4D, 0x18, _:bytes>> if low >= 0x50 && low <= 0x5F ->
      Ok(Compressed(Zstd))
    // The LZ4 frame format and the legacy `lz4 -l` format.
    <<0x04, 0x22, 0x4D, 0x18, _:bytes>> | <<0x02, 0x21, 0x4C, 0x18, _:bytes>> ->
      Ok(Compressed(Lz4))
    <<0xFF, 0x06, 0x00, 0x00, "sNaPpY":utf8, _:bytes>> -> Ok(Compressed(Snappy))
    <<"BZh":utf8, level, _:bytes>> if level >= 0x31 && level <= 0x39 ->
      Ok(Compressed(Bzip2))
    <<0x1F, 0x9D, _:bytes>> -> Ok(Compressed(Lzw))
    <<"!<arch>\n":utf8, _:bytes>> -> Ok(archived(Ar))
    <<"070701":utf8, _:bytes>> -> Ok(archived(Cpio))
    _ ->
      case looks_like_zlib(bytes), bit_array.slice(bytes, 257, 5) {
        True, _ -> Ok(Compressed(Zlib))
        False, Ok(<<"ustar":utf8>>) -> Ok(archived(Tar))
        False, _ -> Error(Nil)
      }
  }
}

// A zlib header has method 8, a window of at most 32 KiB, and a check
// value that makes the first two bytes a multiple of 31.
fn looks_like_zlib(bytes: BitArray) -> Bool {
  case bytes {
    <<cmf, flg, _:bytes>> -> {
      let method = int.bitwise_and(cmf, 0x0F)
      let window = int.bitwise_shift_right(cmf, 4)
      method == 8 && window <= 7 && { cmf * 256 + flg } % 31 == 0
    }
    _ -> False
  }
}

/// Detects a format from the file name, and from the first bytes of the
/// file when the name says nothing, such as for `-` or an upload with a
/// random name.
///
pub fn detect(
  path path: String,
  bytes bytes: BitArray,
) -> Result(Detected, Nil) {
  detect_filename(path)
  |> result.lazy_or(fn() { detect_bytes(bytes) })
}
