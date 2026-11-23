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
import packkit/archive
import packkit/internal/bytes
import packkit/internal/entry
import packkit/limit

const magic: String = "!<arch>\n"

const header_size: Int = 60

const end_marker_byte: Int = 0x60

const newline: Int = 0x0A

/// Encode the logical archive to an `ar` byte stream.
pub fn encode(
  archive archive_value: archive.Archive,
) -> Result(BitArray, archive.ArchiveError) {
  use _ <- result.try(entry.reject_comment(archive_value))
  archive_value.entries
  |> list.try_map(encode_entry)
  |> result.map(fn(records) {
    [bit_array.from_string(magic), bit_array.concat(records)]
    |> bit_array.concat
  })
}

/// Decode an `ar` byte stream using explicit limits.
pub fn decode_with_limits(
  bytes bytes: BitArray,
  limits limits: limit.Limits,
) -> Result(archive.Archive, archive.ArchiveError) {
  use <- bool.guard(
    when: bit_array.byte_size(bytes) > limits.max_input_bytes,
    return: Error(archive.LimitExceeded(
      limit: "max_input_bytes",
      actual: bit_array.byte_size(bytes),
    )),
  )

  case bytes {
    <<"!<arch>\n":utf8, members:bytes>> ->
      decode_loop(members, [], 0, option.None, limits)
      |> result.try(entry.finish(_, archive.Ar, limits))
    _ -> Error(archive.InvalidData(message: "missing !<arch> magic"))
  }
}

fn decode_loop(
  bytes: BitArray,
  acc: List(archive.Entry),
  count: Int,
  string_table: option.Option(BitArray),
  limits: limit.Limits,
) -> Result(List(archive.Entry), archive.ArchiveError) {
  case bytes {
    <<>> -> Ok(acc)
    <<header_bits:bytes-size(header_size), after_header:bytes>> -> {
      use record <- result.try(parse_header(header_bits))
      // `parse_header` keeps `name_extension` between 0 and `size`.
      let name_size = record.name_extension
      let payload_size = record.size - name_size
      use #(name_bits, payload, remaining) <- result.try(case after_header {
        <<
          name_bits:bytes-size(name_size),
          payload:bytes-size(payload_size),
          remaining:bytes,
        >> -> Ok(#(name_bits, payload, skip_padding(record.size, remaining)))
        _ -> Error(archive.InvalidData(message: "ar entry truncated"))
      })
      case record.special {
        SymbolTable -> decode_loop(remaining, acc, count, string_table, limits)
        StringTable ->
          decode_loop(remaining, acc, count, option.Some(payload), limits)
        RegularEntry -> {
          use _ <- result.try(check_member_limit(count + 1, limits))
          use name <- result.try(resolve_entry_name(
            record,
            name_bits,
            string_table,
          ))
          use <- bool.guard(
            when: string.byte_size(name) > limits.max_entry_name_bytes,
            return: Error(archive.LimitExceeded(
              limit: "max_entry_name_bytes",
              actual: string.byte_size(name),
            )),
          )
          use base_entry <- result.try(
            entry.file_checked(path: name, body: payload)
            |> result.map_error(entry.to_archive_error(_, name)),
          )
          let depth = entry.depth(base_entry.path)
          use <- bool.guard(
            when: depth > limits.max_entry_depth,
            return: Error(archive.LimitExceeded(
              limit: "max_entry_depth",
              actual: depth,
            )),
          )
          let entry_value =
            archive.Entry(
              ..base_entry,
              mode: record.mode,
              user_id: record.uid,
              group_id: record.gid,
              modified_at: record.mtime,
            )
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
    _ -> Error(archive.InvalidData(message: "ar entry header truncated"))
  }
}

// Members start on an even offset, so an odd-sized member is followed by
// one padding byte. The last member may omit it.
fn skip_padding(size: Int, bytes: BitArray) -> BitArray {
  case size % 2, bytes {
    1, <<_, rest:bytes>> -> rest
    _, _ -> bytes
  }
}

fn resolve_entry_name(
  record: ParsedRecord,
  name_bits: BitArray,
  string_table: option.Option(BitArray),
) -> Result(String, archive.ArchiveError) {
  case record.name_extension, record.gnu_offset {
    // BSD long name lives in the bytes immediately after the header.
    n, _ if n > 0 -> bytes_to_string(bytes.strip_trailing_nul(name_bits))
    // GNU long name reference (`/<offset>`).
    _, option.Some(offset) ->
      case string_table {
        option.None ->
          Error(archive.InvalidData(
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
) -> Result(String, archive.ArchiveError) {
  let out_of_range =
    Error(archive.InvalidData(
      message: "ar GNU string table offset out of range",
    ))
  use <- bool.guard(
    when: offset < 0 || offset >= bit_array.byte_size(table),
    return: out_of_range,
  )
  case table {
    <<_:bytes-size(offset), tail:bytes>> ->
      bytes_to_string(take_gnu_name(tail, <<>>))
    _ -> out_of_range
  }
}

// GNU writes "<name>/\n"; some toolchains write "<name>\0".
fn take_gnu_name(bytes: BitArray, acc: BitArray) -> BitArray {
  case bytes {
    <<0x2F, _:bytes>> | <<0x00, _:bytes>> | <<0x0A, _:bytes>> -> acc
    <<byte, rest:bytes>> -> take_gnu_name(rest, <<acc:bits, byte>>)
    _ -> acc
  }
}

fn check_member_limit(
  count: Int,
  limits: limit.Limits,
) -> Result(Nil, archive.ArchiveError) {
  case count > limits.max_members {
    True -> Error(archive.LimitExceeded(limit: "max_members", actual: count))
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

fn parse_header(block: BitArray) -> Result(ParsedRecord, archive.ArchiveError) {
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
    return: Error(archive.InvalidData(message: "ar header marker missing")),
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
            Ok(len) if len >= 0 && len <= size ->
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
            _ ->
              Error(archive.InvalidData(
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
                  Error(archive.InvalidData(
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

fn encode_entry(
  value: archive.Entry,
) -> Result(BitArray, archive.ArchiveError) {
  use body <- result.try(case value.kind {
    archive.File(body) -> Ok(body)
    archive.Directory | archive.Symlink(_) | archive.Hardlink(_) ->
      Error(archive.EntryRejected(
        path: value.path,
        reason: "ar only supports regular file entries",
      ))
  })

  let path = value.path
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
    value.modified_at,
    12,
    "mtime",
  ))
  use uid_field <- result.try(checked_decimal_field(value.user_id, 6, "uid"))
  use gid_field <- result.try(checked_decimal_field(value.group_id, 6, "gid"))
  use mode_field <- result.try(checked_octal_field(value.mode, 8, "mode"))
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
  bytes.pad_end(bytes, width, 0x20)
}

fn decimal_field(value: Int, width: Int) -> BitArray {
  let raw = int.to_string(value)
  let raw_bits = bit_array.from_string(raw)
  bytes.pad_end(raw_bits, width, 0x20)
}

fn checked_decimal_field(
  value: Int,
  width: Int,
  field: String,
) -> Result(BitArray, archive.ArchiveError) {
  let raw = int.to_string(value)
  let raw_size = string.byte_size(raw)
  case value < 0 || raw_size > width {
    True -> {
      let max_value = pow_int(10, width) - 1
      Error(archive.FieldOverflow(
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
) -> Result(BitArray, archive.ArchiveError) {
  let raw = int.to_base8(value)
  let raw_size = string.byte_size(raw)
  case value < 0 || raw_size > width {
    True -> {
      let max_value = pow_int(8, width) - 1
      Error(archive.FieldOverflow(
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
  bytes.pad_end(raw_bits, width, 0x20)
}

fn read_decimal_field(
  block: BitArray,
  offset: Int,
  width: Int,
) -> Result(Int, archive.ArchiveError) {
  use slice <- result.try(slice_or_error(block, offset, width))
  use raw <- result.try(bytes_to_string(slice))
  let trimmed = string.trim(raw)
  case trimmed {
    "" -> Ok(0)
    _ ->
      case int.parse(trimmed) {
        Ok(value) if value >= 0 -> Ok(value)
        _ -> Error(archive.InvalidData(message: "invalid decimal ar field"))
      }
  }
}

fn read_octal_field(
  block: BitArray,
  offset: Int,
  width: Int,
) -> Result(Int, archive.ArchiveError) {
  use slice <- result.try(slice_or_error(block, offset, width))
  use raw <- result.try(bytes_to_string(slice))
  let trimmed = string.trim(raw)
  case trimmed {
    "" -> Ok(0)
    _ ->
      case int.base_parse(trimmed, 8) {
        Ok(value) if value >= 0 -> Ok(value)
        _ -> Error(archive.InvalidData(message: "invalid octal ar field"))
      }
  }
}

fn slice_or_error(
  block: BitArray,
  offset: Int,
  width: Int,
) -> Result(BitArray, archive.ArchiveError) {
  case bit_array.slice(block, offset, width) {
    Ok(value) -> Ok(value)
    Error(_) ->
      Error(archive.InvalidData(message: "ar header field out of bounds"))
  }
}

fn bytes_to_string(bytes: BitArray) -> Result(String, archive.ArchiveError) {
  case bit_array.to_string(bytes) {
    Ok(value) -> Ok(value)
    Error(_) ->
      Error(archive.InvalidData(message: "non-UTF-8 ar header string"))
  }
}

fn strip_trailing_slash(value: String) -> String {
  case string.ends_with(value, "/") {
    True -> string.drop_end(value, 1)
    False -> value
  }
}
