//// Unix `ar` archive encoder and decoder.
////
//// The encoder emits the BSD long-name variant (`#1/N`) so it can
//// carry archive entries whose paths exceed 16 bytes or contain
//// spaces.  The decoder additionally accepts the GNU long-name
//// variant (a leading `//` string-table member plus `/<offset>`
//// references in entry headers), which is the form produced by
//// `binutils` ar and present in nearly every `.deb` / `.a` on
//// Linux.  GNU symbol-table members (named `/`) are skipped
//// transparently so they do not show up as user-visible entries.
////
//// Only regular file entries are supported - `ar` does not represent
//// directories or symbolic links.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import packkit/archive as archives
import packkit/entry
import packkit/error
import packkit/limit

const magic: String = "!<arch>\n"

const magic_size: Int = 8

const header_size: Int = 60

const end_marker_byte: Int = 0x60

const newline: Int = 0x0A

/// AR archive format marker.
pub fn format() -> archives.ArchiveFormat {
  archives.ar()
}

/// Create an empty AR archive value.
pub fn new() -> archives.Archive {
  archives.new(format: format())
}

/// Encode the logical archive to an `ar` byte stream.
pub fn encode(
  archive archive_value: archives.Archive,
) -> Result(BitArray, error.ArchiveError) {
  use _ <- result.try(reject_comment(archive_value))
  archive_value
  |> archives.entries
  |> list.try_map(encode_entry)
  |> result.map(fn(records) {
    [bit_array.from_string(magic), bit_array.concat(records)]
    |> bit_array.concat
  })
}

fn reject_comment(
  archive_value: archives.Archive,
) -> Result(Nil, error.ArchiveError) {
  case archives.comment(archive_value) {
    option.None -> Ok(Nil)
    option.Some(_) -> Error(error.ArchiveCommentUnsupported(format: "ar"))
  }
}

/// Decode an `ar` byte stream using default limits.
pub fn decode(
  bytes bytes: BitArray,
) -> Result(archives.Archive, error.ArchiveError) {
  decode_with_limits(bytes: bytes, limits: limit.default())
}

/// Decode an `ar` byte stream using explicit limits.
pub fn decode_with_limits(
  bytes bytes: BitArray,
  limits limits: limit.Limits,
) -> Result(archives.Archive, error.ArchiveError) {
  use <- bool.guard(
    when: bit_array.byte_size(bytes) > limit.max_input_bytes(limits),
    return: Error(error.ArchiveLimitExceeded(
      limit: "max_input_bytes",
      actual: bit_array.byte_size(bytes),
    )),
  )

  use header_bits <- result.try(slice_or_error(bytes, 0, magic_size))
  use header_string <- result.try(bytes_to_string(header_bits))
  use <- bool.guard(
    when: header_string != magic,
    return: Error(error.ArchiveInvalid(message: "missing !<arch> magic")),
  )

  let body_size = bit_array.byte_size(bytes) - magic_size
  let assert Ok(rest) = bit_array.slice(bytes, magic_size, body_size)
  decode_loop(rest, [], 0, option.None, limits)
  |> result.map(list.reverse)
  |> result.map(archives.from_entries(format: format(), entries: _))
}

fn decode_loop(
  bytes: BitArray,
  acc: List(entry.Entry),
  count: Int,
  string_table: option.Option(BitArray),
  limits: limit.Limits,
) -> Result(List(entry.Entry), error.ArchiveError) {
  case bit_array.byte_size(bytes) {
    0 -> Ok(acc)
    _ ->
      case bit_array.byte_size(bytes) < header_size {
        True ->
          Error(error.ArchiveInvalid(message: "ar entry header truncated"))
        False -> {
          let assert Ok(header_bits) = bit_array.slice(bytes, 0, header_size)
          use record <- result.try(parse_header(header_bits))

          let after_header_offset = header_size
          let payload_offset = after_header_offset + record.name_extension
          let payload_size = record.size - record.name_extension
          let total_size = header_size + record.size
          let padded_size = case total_size % 2 {
            0 -> total_size
            _ -> total_size + 1
          }

          use <- bool.guard(
            when: bit_array.byte_size(bytes) < payload_offset + payload_size,
            return: Error(error.ArchiveInvalid(message: "ar entry truncated")),
          )

          let advance = min(padded_size, bit_array.byte_size(bytes))
          let assert Ok(remaining) =
            bit_array.slice(
              bytes,
              advance,
              bit_array.byte_size(bytes) - advance,
            )

          case record.special {
            SymbolTable ->
              decode_loop(remaining, acc, count, string_table, limits)
            StringTable -> {
              let assert Ok(table_body) =
                bit_array.slice(bytes, payload_offset, payload_size)
              decode_loop(
                remaining,
                acc,
                count,
                option.Some(table_body),
                limits,
              )
            }
            RegularEntry -> {
              use _ <- result.try(check_member_limit(count + 1, limits))

              use name <- result.try(resolve_entry_name(
                record,
                bytes,
                after_header_offset,
                string_table,
              ))

              use <- bool.guard(
                when: string.byte_size(name)
                  > limit.max_entry_name_bytes(limits),
                return: Error(error.ArchiveLimitExceeded(
                  limit: "max_entry_name_bytes",
                  actual: string.byte_size(name),
                )),
              )

              let assert Ok(body) =
                bit_array.slice(bytes, payload_offset, payload_size)
              use base_entry <- result.try(
                entry.file_checked(path: name, body: body)
                |> result.map_error(entry_error_to_archive_error(_, name)),
              )

              let depth = entry.depth(entry.path(base_entry))
              use <- bool.guard(
                when: depth > limit.max_entry_depth(limits),
                return: Error(error.ArchiveLimitExceeded(
                  limit: "max_entry_depth",
                  actual: depth,
                )),
              )

              let entry_value =
                base_entry
                |> entry.with_mode(mode: record.mode)
                |> entry.with_owner(user_id: record.uid, group_id: record.gid)
                |> entry.with_modified_at(unix_seconds: record.mtime)

              decode_loop(
                remaining,
                [entry_value, ..acc],
                count + 1,
                string_table,
                limits,
              )
            }
          }
        }
      }
  }
}

fn resolve_entry_name(
  record: ParsedRecord,
  bytes: BitArray,
  after_header_offset: Int,
  string_table: option.Option(BitArray),
) -> Result(String, error.ArchiveError) {
  case record.name_extension, record.gnu_offset {
    // BSD long name lives in the bytes immediately after the header.
    n, _ if n > 0 -> {
      use ext_bits <- result.try(slice_or_error(
        bytes,
        after_header_offset,
        record.name_extension,
      ))
      bytes_to_string(strip_trailing_nul(ext_bits))
    }
    // GNU long name reference (`/<offset>`).
    _, option.Some(offset) ->
      case string_table {
        option.None ->
          Error(error.ArchiveInvalid(
            message: "ar entry references missing GNU string table",
          ))
        option.Some(table) -> gnu_string_at(table, offset)
      }
    _, option.None -> Ok(record.header_name)
  }
}

fn gnu_string_at(
  table: BitArray,
  offset: Int,
) -> Result(String, error.ArchiveError) {
  let size = bit_array.byte_size(table)
  case offset < 0 || offset >= size {
    True ->
      Error(error.ArchiveInvalid(
        message: "ar GNU string table offset out of range",
      ))
    False -> {
      let assert Ok(tail) = bit_array.slice(table, offset, size - offset)
      let end_index = find_gnu_terminator(tail, 0, size - offset)
      let assert Ok(name_bits) = bit_array.slice(tail, 0, end_index)
      bytes_to_string(name_bits)
    }
  }
}

fn find_gnu_terminator(bytes: BitArray, pos: Int, len: Int) -> Int {
  case pos >= len {
    True -> len
    False ->
      case bit_array.slice(bytes, pos, 1) {
        // GNU writes "<name>/\n"; some toolchains write "<name>\0".
        Ok(<<0x2F>>) -> pos
        Ok(<<0x00>>) -> pos
        Ok(<<0x0A>>) -> pos
        _ -> find_gnu_terminator(bytes, pos + 1, len)
      }
  }
}

fn check_member_limit(
  count: Int,
  limits: limit.Limits,
) -> Result(Nil, error.ArchiveError) {
  case count > limit.max_members(limits) {
    True ->
      Error(error.ArchiveLimitExceeded(limit: "max_members", actual: count))
    False -> Ok(Nil)
  }
}

type SpecialKind {
  RegularEntry
  SymbolTable
  StringTable
}

type ParsedRecord {
  ParsedRecord(
    header_name: String,
    name_extension: Int,
    gnu_offset: option.Option(Int),
    special: SpecialKind,
    mtime: Int,
    uid: Int,
    gid: Int,
    mode: Int,
    size: Int,
  )
}

fn parse_header(block: BitArray) -> Result(ParsedRecord, error.ArchiveError) {
  use raw_name_bits <- result.try(slice_or_error(block, 0, 16))
  use raw_name <- result.try(bytes_to_string(raw_name_bits))
  let trimmed_name = string.trim_end(raw_name)

  use mtime <- result.try(read_decimal_field(block, 16, 12))
  use uid <- result.try(read_decimal_field(block, 28, 6))
  use gid <- result.try(read_decimal_field(block, 34, 6))
  use mode <- result.try(read_octal_field(block, 40, 8))
  use size <- result.try(read_decimal_field(block, 48, 10))
  use ending_bits <- result.try(slice_or_error(block, 58, 2))
  use <- bool.guard(
    when: ending_bits != <<end_marker_byte, newline>>,
    return: Error(error.ArchiveInvalid(message: "ar header marker missing")),
  )

  case trimmed_name {
    "/" | "/SYM64/" ->
      Ok(ParsedRecord(
        header_name: trimmed_name,
        name_extension: 0,
        gnu_offset: option.None,
        special: SymbolTable,
        mtime: mtime,
        uid: uid,
        gid: gid,
        mode: mode,
        size: size,
      ))
    "//" | "ARFILENAMES/" ->
      Ok(ParsedRecord(
        header_name: trimmed_name,
        name_extension: 0,
        gnu_offset: option.None,
        special: StringTable,
        mtime: mtime,
        uid: uid,
        gid: gid,
        mode: mode,
        size: size,
      ))
    _ ->
      case string.starts_with(trimmed_name, "#1/") {
        True -> {
          let len_string = string.drop_start(trimmed_name, 3)
          case int.parse(len_string) {
            Ok(len) ->
              Ok(ParsedRecord(
                header_name: "",
                name_extension: len,
                gnu_offset: option.None,
                special: RegularEntry,
                mtime: mtime,
                uid: uid,
                gid: gid,
                mode: mode,
                size: size,
              ))
            Error(_) ->
              Error(error.ArchiveInvalid(
                message: "invalid BSD long name length in ar header",
              ))
          }
        }
        False ->
          case string.starts_with(trimmed_name, "/") {
            True -> {
              let offset_string = string.drop_start(trimmed_name, 1)
              case int.parse(offset_string) {
                Ok(offset) ->
                  Ok(ParsedRecord(
                    header_name: "",
                    name_extension: 0,
                    gnu_offset: option.Some(offset),
                    special: RegularEntry,
                    mtime: mtime,
                    uid: uid,
                    gid: gid,
                    mode: mode,
                    size: size,
                  ))
                Error(_) ->
                  Error(error.ArchiveInvalid(
                    message: "invalid GNU long name offset in ar header",
                  ))
              }
            }
            False ->
              Ok(ParsedRecord(
                header_name: strip_trailing_slash(trimmed_name),
                name_extension: 0,
                gnu_offset: option.None,
                special: RegularEntry,
                mtime: mtime,
                uid: uid,
                gid: gid,
                mode: mode,
                size: size,
              ))
          }
      }
  }
}

fn encode_entry(value: entry.Entry) -> Result(BitArray, error.ArchiveError) {
  let kind = entry.kind(value)
  use <- bool.guard(
    when: kind != entry.File,
    return: Error(error.ArchiveEntryRejected(
      path: entry.to_string(entry.path(value)),
      reason: "ar only supports regular file entries",
    )),
  )

  let path = entry.to_string(entry.path(value))
  let metadata = entry.metadata(value)
  let body = entry.body(value)
  let body_size = bit_array.byte_size(body)

  let name_bytes = bit_array.from_string(path)
  let name_size = bit_array.byte_size(name_bytes)
  let needs_long_name =
    name_size > 16 || string.contains(path, " ") || string.contains(path, "/")

  let #(name_field, name_extension_bytes, total_size) = case needs_long_name {
    True -> {
      let extension_size = name_size
      let label = "#1/" <> int.to_string(extension_size)
      #(text_field(label, 16), name_bytes, body_size + extension_size)
    }
    False -> #(text_field(path, 16), <<>>, body_size)
  }

  use mtime_field <- result.try(checked_decimal_field(
    entry.modified_at_unix(metadata),
    12,
    "mtime",
  ))
  use uid_field <- result.try(checked_decimal_field(
    entry.user_id(metadata),
    6,
    "uid",
  ))
  use gid_field <- result.try(checked_decimal_field(
    entry.group_id(metadata),
    6,
    "gid",
  ))
  use mode_field <- result.try(checked_octal_field(
    entry.mode(metadata),
    8,
    "mode",
  ))
  use size_field <- result.try(checked_decimal_field(total_size, 10, "size"))

  let header =
    bit_array.concat([
      name_field,
      mtime_field,
      uid_field,
      gid_field,
      mode_field,
      size_field,
      <<end_marker_byte, newline>>,
    ])

  let combined = bit_array.concat([header, name_extension_bytes, body])
  let padded = case total_size % 2 {
    0 -> combined
    _ -> bit_array.concat([combined, <<newline>>])
  }

  Ok(padded)
}

fn text_field(value: String, width: Int) -> BitArray {
  let bytes = bit_array.from_string(value)
  right_pad(bytes, width, 0x20)
}

fn decimal_field(value: Int, width: Int) -> BitArray {
  let raw = int.to_string(value)
  let raw_bits = bit_array.from_string(raw)
  right_pad(raw_bits, width, 0x20)
}

fn checked_decimal_field(
  value: Int,
  width: Int,
  field: String,
) -> Result(BitArray, error.ArchiveError) {
  let raw = int.to_string(value)
  let raw_size = string.byte_size(raw)
  case value < 0 || raw_size > width {
    True -> {
      let max_value = pow_int(10, width) - 1
      Error(error.ArchiveFieldOverflow(
        field: "ar " <> field,
        value: value,
        max: max_value,
      ))
    }
    False -> Ok(decimal_field(value, width))
  }
}

fn checked_octal_field(
  value: Int,
  width: Int,
  field: String,
) -> Result(BitArray, error.ArchiveError) {
  let raw = int.to_base8(value)
  let raw_size = string.byte_size(raw)
  case value < 0 || raw_size > width {
    True -> {
      let max_value = pow_int(8, width) - 1
      Error(error.ArchiveFieldOverflow(
        field: "ar " <> field,
        value: value,
        max: max_value,
      ))
    }
    False -> Ok(octal_field(value, width))
  }
}

fn pow_int(base: Int, exponent: Int) -> Int {
  pow_int_loop(base, exponent, 1)
}

fn pow_int_loop(base: Int, exponent: Int, acc: Int) -> Int {
  case exponent {
    0 -> acc
    _ -> pow_int_loop(base, exponent - 1, acc * base)
  }
}

fn octal_field(value: Int, width: Int) -> BitArray {
  let raw = int.to_base8(value)
  let raw_bits = bit_array.from_string(raw)
  right_pad(raw_bits, width, 0x20)
}

fn right_pad(value: BitArray, width: Int, fill: Int) -> BitArray {
  let size = bit_array.byte_size(value)
  case size >= width {
    True -> {
      let assert Ok(slice) = bit_array.slice(value, 0, width)
      slice
    }
    False -> bit_array.concat([value, byte_repeat(fill, width - size)])
  }
}

fn byte_repeat(byte: Int, count: Int) -> BitArray {
  byte_repeat_loop(byte, count, <<>>)
}

fn byte_repeat_loop(byte: Int, count: Int, acc: BitArray) -> BitArray {
  case count {
    0 -> acc
    _ -> byte_repeat_loop(byte, count - 1, <<acc:bits, byte>>)
  }
}

fn read_decimal_field(
  block: BitArray,
  offset: Int,
  width: Int,
) -> Result(Int, error.ArchiveError) {
  use slice <- result.try(slice_or_error(block, offset, width))
  use raw <- result.try(bytes_to_string(slice))
  let trimmed = string.trim(raw)
  case trimmed {
    "" -> Ok(0)
    _ ->
      case int.parse(trimmed) {
        Ok(value) -> Ok(value)
        Error(_) ->
          Error(error.ArchiveInvalid(message: "invalid decimal ar field"))
      }
  }
}

fn read_octal_field(
  block: BitArray,
  offset: Int,
  width: Int,
) -> Result(Int, error.ArchiveError) {
  use slice <- result.try(slice_or_error(block, offset, width))
  use raw <- result.try(bytes_to_string(slice))
  let trimmed = string.trim(raw)
  case trimmed {
    "" -> Ok(0)
    _ ->
      case int.base_parse(trimmed, 8) {
        Ok(value) -> Ok(value)
        Error(_) ->
          Error(error.ArchiveInvalid(message: "invalid octal ar field"))
      }
  }
}

fn slice_or_error(
  block: BitArray,
  offset: Int,
  width: Int,
) -> Result(BitArray, error.ArchiveError) {
  case bit_array.slice(block, offset, width) {
    Ok(value) -> Ok(value)
    Error(_) ->
      Error(error.ArchiveInvalid(message: "ar header field out of bounds"))
  }
}

fn bytes_to_string(bytes: BitArray) -> Result(String, error.ArchiveError) {
  case bit_array.to_string(bytes) {
    Ok(value) -> Ok(value)
    Error(_) ->
      Error(error.ArchiveInvalid(message: "non-UTF-8 ar header string"))
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

fn strip_trailing_slash(value: String) -> String {
  case string.ends_with(value, "/") {
    True -> string.drop_end(value, 1)
    False -> value
  }
}

fn strip_trailing_nul(bytes: BitArray) -> BitArray {
  let size = bit_array.byte_size(bytes)
  strip_trailing_nul_loop(bytes, size)
}

fn strip_trailing_nul_loop(bytes: BitArray, size: Int) -> BitArray {
  case size {
    0 -> <<>>
    _ ->
      case bit_array.slice(bytes, size - 1, 1) {
        Ok(<<0>>) -> strip_trailing_nul_loop(bytes, size - 1)
        _ -> {
          let assert Ok(slice) = bit_array.slice(bytes, 0, size)
          slice
        }
      }
  }
}

fn min(a: Int, b: Int) -> Int {
  case a < b {
    True -> a
    False -> b
  }
}
