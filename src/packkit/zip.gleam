//// ZIP archive encoder and decoder.
////
//// This module implements the PKZIP local-file-header / central
//// directory layout for the "stored" (uncompressed) method.  ZIP is
//// modelled as an archive family, not a recipe: per-entry compression
//// is selected through `Method` values rather than through
//// `packkit/recipe`.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import packkit/archive as archives
import packkit/checksum
import packkit/codec as codecs
import packkit/entry
import packkit/error
import packkit/level
import packkit/limit

const local_file_signature: Int = 0x04034b50

const central_directory_signature: Int = 0x02014b50

const eocd_signature: Int = 0x06054b50

const method_store: Int = 0

const version_made_by_unix: Int = 0x0314

const version_needed_store: Int = 10

const external_attr_dir: Int = 0x4000_0000

const default_mtime_dos: Int = 0x0021

const default_mdate_dos: Int = 0x0021

/// ZIP-specific entry method marker. This stays distinct from the
/// top-level recipe model because ZIP is an archive family, not a
/// recipe.
pub opaque type Method {
  Method(name: String, inner_codec: Option(codecs.Codec))
}

/// ZIP archive format marker.
pub fn format() -> archives.ArchiveFormat {
  archives.zip()
}

/// Create an empty logical ZIP archive value.
pub fn new() -> archives.Archive {
  archives.new(format: format())
}

/// Stored (uncompressed) ZIP member method.
pub fn store() -> Method {
  Method(name: "store", inner_codec: None)
}

/// Deflate-compressed ZIP member method.
pub fn deflate(level level: level.Level) -> Method {
  Method(
    name: "deflate",
    inner_codec: Some(codecs.deflate() |> codecs.with_level(level: level)),
  )
}

/// Stable method name.
pub fn name(method: Method) -> String {
  method.name
}

/// Optional inner codec corresponding to the method.
pub fn inner_codec(method: Method) -> Option(codecs.Codec) {
  method.inner_codec
}

/// Encode a logical archive into a ZIP byte stream using the stored
/// (uncompressed) method for every entry.
pub fn encode(
  archive archive_value: archives.Archive,
) -> Result(BitArray, error.ArchiveError) {
  let entries = archives.entries(archive_value)
  use #(local_blocks, central_blocks) <- result.try(
    encode_entries(entries, 0, [], []),
  )

  let local_bytes = bit_array.concat(local_blocks)
  let central_bytes = bit_array.concat(central_blocks)
  let central_offset = bit_array.byte_size(local_bytes)
  let central_size = bit_array.byte_size(central_bytes)
  let count = list.length(entries)

  let eocd =
    bit_array.concat([
      le32(eocd_signature),
      le16(0),
      le16(0),
      le16(count),
      le16(count),
      le32(central_size),
      le32(central_offset),
      le16(0),
    ])

  Ok(bit_array.concat([local_bytes, central_bytes, eocd]))
}

/// Decode a ZIP archive using default limits.
pub fn decode(
  bytes bytes: BitArray,
) -> Result(archives.Archive, error.ArchiveError) {
  decode_with_limits(bytes: bytes, limits: limit.default())
}

/// Decode a ZIP archive using explicit limits.
pub fn decode_with_limits(
  bytes bytes: BitArray,
  limits limits: limit.Limits,
) -> Result(archives.Archive, error.ArchiveError) {
  use <- bool.guard(
    when: bit_array.byte_size(bytes) > limit.max_input_bytes(limits),
    return: Error(error.ArchiveLimitExceeded(
      limit: "max_input_bytes",
      value: bit_array.byte_size(bytes),
    )),
  )

  use eocd_offset <- result.try(locate_eocd(bytes))
  use eocd <- result.try(read_eocd(bytes, eocd_offset))

  use <- bool.guard(
    when: eocd.total_entries > limit.max_members(limits),
    return: Error(error.ArchiveLimitExceeded(
      limit: "max_members",
      value: eocd.total_entries,
    )),
  )

  use central_bits <- result.try(slice_or_error(
    bytes,
    eocd.central_offset,
    eocd.central_size,
  ))

  use entries <- result.try(parse_central_directory(
    central_bits,
    [],
    eocd.total_entries,
    bytes,
    limits,
  ))

  Ok(archives.from_entries(format: format(), entries: list.reverse(entries)))
}

fn encode_entries(
  remaining: List(entry.Entry),
  offset: Int,
  local_acc: List(BitArray),
  central_acc: List(BitArray),
) -> Result(#(List(BitArray), List(BitArray)), error.ArchiveError) {
  case remaining {
    [] -> Ok(#(list.reverse(local_acc), list.reverse(central_acc)))
    [head, ..rest] -> {
      use built <- result.try(encode_entry(head, offset))
      let #(local_record, central_record, advance) = built
      encode_entries(rest, offset + advance, [local_record, ..local_acc], [
        central_record,
        ..central_acc
      ])
    }
  }
}

fn encode_entry(
  value: entry.Entry,
  offset: Int,
) -> Result(#(BitArray, BitArray, Int), error.ArchiveError) {
  let kind = entry.kind(value)
  let raw_path = entry.to_string(entry.path_of(value))

  use <- bool.guard(
    when: kind == "symlink" || kind == "hardlink",
    return: Error(error.ArchiveEntryRejected(
      path: raw_path,
      reason: "ZIP encode currently supports files and directories only",
    )),
  )

  let canonical_path = case kind {
    "directory" -> ensure_trailing_slash(raw_path)
    _ -> raw_path
  }

  let name_bytes = bit_array.from_string(canonical_path)
  let name_length = bit_array.byte_size(name_bytes)

  use <- bool.guard(
    when: name_length > 65_535,
    return: Error(error.ArchiveEntryRejected(
      path: canonical_path,
      reason: "ZIP entry name longer than 65535 bytes",
    )),
  )

  let body = case kind {
    "directory" -> <<>>
    _ -> entry.body(value)
  }

  let size = bit_array.byte_size(body)
  let crc = case kind {
    "directory" -> 0
    _ -> checksum.crc32(body)
  }
  let metadata = entry.metadata(value)
  let mode = entry.mode(metadata)
  let external_attrs = case kind {
    "directory" ->
      int.bitwise_or(external_attr_dir, int.bitwise_shift_left(mode, 16))
    _ -> int.bitwise_shift_left(mode, 16)
  }

  let local_header =
    bit_array.concat([
      le32(local_file_signature),
      le16(version_needed_store),
      le16(0),
      le16(method_store),
      le16(default_mtime_dos),
      le16(default_mdate_dos),
      le32(crc),
      le32(size),
      le32(size),
      le16(name_length),
      le16(0),
      name_bytes,
    ])

  let local_record = bit_array.concat([local_header, body])
  let local_record_size = bit_array.byte_size(local_record)

  let central_record =
    bit_array.concat([
      le32(central_directory_signature),
      le16(version_made_by_unix),
      le16(version_needed_store),
      le16(0),
      le16(method_store),
      le16(default_mtime_dos),
      le16(default_mdate_dos),
      le32(crc),
      le32(size),
      le32(size),
      le16(name_length),
      le16(0),
      le16(0),
      le16(0),
      le16(0),
      le32(external_attrs),
      le32(offset),
      name_bytes,
    ])

  Ok(#(local_record, central_record, local_record_size))
}

fn ensure_trailing_slash(value: String) -> String {
  case string.ends_with(value, "/") {
    True -> value
    False -> value <> "/"
  }
}

type EocdRecord {
  EocdRecord(total_entries: Int, central_offset: Int, central_size: Int)
}

fn locate_eocd(bytes: BitArray) -> Result(Int, error.ArchiveError) {
  let size = bit_array.byte_size(bytes)
  case size < 22 {
    True -> Error(error.ArchiveInvalid(message: "ZIP stream too short"))
    False -> {
      let start = case size - 22 - 65_535 < 0 {
        True -> 0
        False -> size - 22 - 65_535
      }
      scan_eocd(bytes, size - 22, start)
    }
  }
}

fn scan_eocd(
  bytes: BitArray,
  position: Int,
  floor: Int,
) -> Result(Int, error.ArchiveError) {
  case position < floor {
    True -> Error(error.ArchiveInvalid(message: "missing ZIP EOCD signature"))
    False ->
      case bit_array.slice(bytes, position, 4) {
        Ok(slice) ->
          case read_le32(slice) {
            Ok(value) if value == eocd_signature -> Ok(position)
            _ -> scan_eocd(bytes, position - 1, floor)
          }
        Error(_) -> scan_eocd(bytes, position - 1, floor)
      }
  }
}

fn read_eocd(
  bytes: BitArray,
  position: Int,
) -> Result(EocdRecord, error.ArchiveError) {
  use total_entries <- result.try(read_le16_at(bytes, position + 10))
  use central_size <- result.try(read_le32_at(bytes, position + 12))
  use central_offset <- result.try(read_le32_at(bytes, position + 16))
  Ok(EocdRecord(
    total_entries: total_entries,
    central_offset: central_offset,
    central_size: central_size,
  ))
}

fn parse_central_directory(
  bytes: BitArray,
  acc: List(entry.Entry),
  remaining: Int,
  full: BitArray,
  limits: limit.Limits,
) -> Result(List(entry.Entry), error.ArchiveError) {
  case remaining {
    0 -> Ok(acc)
    _ -> {
      use signature <- result.try(read_le32_at(bytes, 0))
      use <- bool.guard(
        when: signature != central_directory_signature,
        return: Error(error.ArchiveInvalid(
          message: "missing ZIP central directory signature",
        )),
      )

      use method <- result.try(read_le16_at(bytes, 10))
      use crc <- result.try(read_le32_at(bytes, 16))
      use comp_size <- result.try(read_le32_at(bytes, 20))
      use uncomp_size <- result.try(read_le32_at(bytes, 24))
      use name_length <- result.try(read_le16_at(bytes, 28))
      use extra_length <- result.try(read_le16_at(bytes, 30))
      use comment_length <- result.try(read_le16_at(bytes, 32))
      use external_attrs <- result.try(read_le32_at(bytes, 38))
      use local_offset <- result.try(read_le32_at(bytes, 42))

      let name_offset = 46
      use name_bits <- result.try(slice_or_error(
        bytes,
        name_offset,
        name_length,
      ))
      use name <- result.try(bytes_to_string(name_bits))

      use <- bool.guard(
        when: string.byte_size(name) > limit.max_entry_name_bytes(limits),
        return: Error(error.ArchiveLimitExceeded(
          limit: "max_entry_name_bytes",
          value: string.byte_size(name),
        )),
      )

      use <- bool.guard(
        when: method != method_store,
        return: Error(error.ArchiveNotImplemented(
          feature: "ZIP method " <> int.to_string(method),
        )),
      )

      use entry_value <- result.try(read_local_entry(
        full,
        local_offset,
        name,
        crc,
        uncomp_size,
        comp_size,
        external_attrs,
      ))

      let record_size = 46 + name_length + extra_length + comment_length
      let next_bits = case
        bit_array.slice(
          bytes,
          record_size,
          bit_array.byte_size(bytes) - record_size,
        )
      {
        Ok(value) -> value
        Error(_) -> <<>>
      }

      parse_central_directory(
        next_bits,
        [entry_value, ..acc],
        remaining - 1,
        full,
        limits,
      )
    }
  }
}

fn read_local_entry(
  full: BitArray,
  local_offset: Int,
  name: String,
  expected_crc: Int,
  uncomp_size: Int,
  _comp_size: Int,
  external_attrs: Int,
) -> Result(entry.Entry, error.ArchiveError) {
  use signature <- result.try(read_le32_at(full, local_offset))
  use <- bool.guard(
    when: signature != local_file_signature,
    return: Error(error.ArchiveInvalid(
      message: "missing local file header signature",
    )),
  )

  use method <- result.try(read_le16_at(full, local_offset + 8))
  use <- bool.guard(
    when: method != method_store,
    return: Error(error.ArchiveNotImplemented(
      feature: "ZIP method " <> int.to_string(method),
    )),
  )

  use local_name_length <- result.try(read_le16_at(full, local_offset + 26))
  use local_extra_length <- result.try(read_le16_at(full, local_offset + 28))

  let data_offset = local_offset + 30 + local_name_length + local_extra_length

  use body <- result.try(slice_or_error(full, data_offset, uncomp_size))

  use <- bool.guard(
    when: checksum.crc32(body) != expected_crc,
    return: Error(error.ArchiveInvalid(message: "ZIP CRC32 mismatch")),
  )

  let is_directory = string.ends_with(name, "/")
  let mode =
    int.bitwise_and(int.bitwise_shift_right(external_attrs, 16), 0xFFFF)

  case is_directory {
    True ->
      entry.directory_checked(path: strip_trailing_slash(name))
      |> result.map_error(entry_error_to_archive_error(_, name))
      |> result.map(fn(e) {
        case mode {
          0 -> e
          _ -> entry.with_mode(e, mode: mode)
        }
      })
    False ->
      entry.file_checked(path: name, body: body)
      |> result.map_error(entry_error_to_archive_error(_, name))
      |> result.map(fn(e) {
        case mode {
          0 -> e
          _ -> entry.with_mode(e, mode: mode)
        }
      })
  }
}

fn strip_trailing_slash(value: String) -> String {
  case string.ends_with(value, "/") {
    True -> string.drop_end(value, 1)
    False -> value
  }
}

fn entry_error_to_archive_error(
  err: entry.EntryError,
  path: String,
) -> error.ArchiveError {
  case err {
    entry.EmptyPath ->
      error.ArchiveEntryRejected(path: path, reason: "empty path")
    entry.AbsolutePath(_) ->
      error.ArchiveEntryRejected(path: path, reason: "absolute path")
    entry.PathTraversal(_) ->
      error.ArchiveEntryRejected(path: path, reason: "path traversal")
    entry.WindowsPath(_) ->
      error.ArchiveEntryRejected(path: path, reason: "windows path")
    entry.EmptySegment(_) ->
      error.ArchiveEntryRejected(path: path, reason: "empty segment")
    entry.DotSegment(_) ->
      error.ArchiveEntryRejected(path: path, reason: "dot segment")
    entry.ContainsNul(_) ->
      error.ArchiveEntryRejected(path: path, reason: "nul byte")
  }
}

fn slice_or_error(
  bytes: BitArray,
  offset: Int,
  width: Int,
) -> Result(BitArray, error.ArchiveError) {
  case bit_array.slice(bytes, offset, width) {
    Ok(value) -> Ok(value)
    Error(_) -> Error(error.ArchiveInvalid(message: "ZIP slice out of bounds"))
  }
}

fn bytes_to_string(bytes: BitArray) -> Result(String, error.ArchiveError) {
  case bit_array.to_string(bytes) {
    Ok(value) -> Ok(value)
    Error(_) ->
      Error(error.ArchiveInvalid(message: "non-UTF-8 ZIP name (set EFS flag)"))
  }
}

fn le16(value: Int) -> BitArray {
  <<value:size(16)-little>>
}

fn le32(value: Int) -> BitArray {
  <<value:size(32)-little>>
}

fn read_le16_at(bytes: BitArray, offset: Int) -> Result(Int, error.ArchiveError) {
  case bit_array.slice(bytes, offset, 2) {
    Ok(<<value:size(16)-little>>) -> Ok(value)
    _ -> Error(error.ArchiveInvalid(message: "short read for 16-bit value"))
  }
}

fn read_le32_at(bytes: BitArray, offset: Int) -> Result(Int, error.ArchiveError) {
  case bit_array.slice(bytes, offset, 4) {
    Ok(<<value:size(32)-little>>) -> Ok(value)
    _ -> Error(error.ArchiveInvalid(message: "short read for 32-bit value"))
  }
}

fn read_le32(bytes: BitArray) -> Result(Int, error.ArchiveError) {
  case bytes {
    <<value:size(32)-little>> -> Ok(value)
    _ -> Error(error.ArchiveInvalid(message: "short read for 32-bit value"))
  }
}
