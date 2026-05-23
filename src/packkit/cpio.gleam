//// CPIO "newc" (SVR4) archive encoder and decoder.
////
//// The newc format uses fixed 110-byte ASCII hex headers and pads
//// names and bodies to a 4-byte alignment.  This module implements
//// regular files, directories, and symbolic links.  Hard links are
//// rejected because newc represents them through shared inode numbers
//// rather than a distinct typeflag.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import packkit/archive as archives
import packkit/entry
import packkit/error
import packkit/limit

const header_size: Int = 110

const magic_newc: String = "070701"

const trailer_name: String = "TRAILER!!!"

const align: Int = 4

const s_ifreg: Int = 0o100000

const s_ifdir: Int = 0o040000

const s_iflnk: Int = 0o120000

/// CPIO newc archive format marker.
pub fn format() -> archives.ArchiveFormat {
  archives.cpio_newc()
}

/// Create an empty CPIO newc archive value.
pub fn new() -> archives.Archive {
  archives.new(format: format())
}

/// Encode the logical archive to a newc byte stream.
pub fn encode(
  archive archive_value: archives.Archive,
) -> Result(BitArray, error.ArchiveError) {
  use _ <- result.try(reject_comment(archive_value))
  archive_value
  |> archives.entries
  |> list.try_map(encode_entry)
  |> result.map(fn(blocks) {
    [bit_array.concat(blocks), trailer_record()]
    |> bit_array.concat
  })
}

fn reject_comment(
  archive_value: archives.Archive,
) -> Result(Nil, error.ArchiveError) {
  case archives.comment(archive_value) {
    None -> Ok(Nil)
    Some(_) -> Error(error.ArchiveCommentUnsupported(format: "cpio-newc"))
  }
}

/// Decode a newc byte stream using default limits.
pub fn decode(
  bytes bytes: BitArray,
) -> Result(archives.Archive, error.ArchiveError) {
  decode_with_limits(bytes: bytes, limits: limit.default())
}

/// Decode a newc byte stream using explicit limits.
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
  decode_loop(bytes, [], 0, limits)
  |> result.map(list.reverse)
  |> result.map(archives.from_entries(format: format(), entries: _))
}

fn decode_loop(
  bytes: BitArray,
  acc: List(entry.Entry),
  count: Int,
  limits: limit.Limits,
) -> Result(List(entry.Entry), error.ArchiveError) {
  use <- bool.guard(
    when: bit_array.byte_size(bytes) < header_size,
    return: Error(error.ArchiveInvalid(message: "cpio header truncated")),
  )

  let assert Ok(header_bits) = bit_array.slice(bytes, 0, header_size)
  use header <- result.try(parse_header(header_bits))

  let name_offset = header_size
  let name_size = header.namesize
  let assert Ok(name_bytes_with_nul) =
    bit_array.slice(bytes, name_offset, name_size)
  use name <- result.try(
    bytes_to_string(strip_trailing_nul(name_bytes_with_nul)),
  )

  let header_plus_name = header_size + name_size
  let after_name_padding = pad_to_align(header_plus_name)
  let body_offset = after_name_padding
  let body_size = header.filesize
  let body_padding = pad_to_align(body_size) - body_size
  let next_offset = body_offset + body_size + body_padding

  use <- bool.guard(
    when: bit_array.byte_size(bytes) < body_offset + body_size,
    return: Error(error.ArchiveInvalid(message: "cpio entry truncated")),
  )

  case name == trailer_name {
    True -> Ok(acc)
    False -> {
      use _ <- result.try(check_member_limit(count + 1, limits))
      let assert Ok(body) = bit_array.slice(bytes, body_offset, body_size)
      use entry_value <- result.try(header_to_entry(header, name, body, limits))
      let advance = next_offset
      let remaining = bit_array.byte_size(bytes) - advance
      let assert Ok(rest) = bit_array.slice(bytes, advance, remaining)
      decode_loop(rest, [entry_value, ..acc], count + 1, limits)
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

type ParsedHeader {
  ParsedHeader(
    mode: Int,
    uid: Int,
    gid: Int,
    mtime: Int,
    filesize: Int,
    namesize: Int,
  )
}

fn parse_header(block: BitArray) -> Result(ParsedHeader, error.ArchiveError) {
  use magic_bits <- result.try(slice_or_error(block, 0, 6))
  use magic <- result.try(bytes_to_string(magic_bits))
  use <- bool.guard(
    when: magic != magic_newc,
    return: Error(error.ArchiveInvalid(message: "not a newc cpio magic")),
  )

  use mode <- result.try(read_hex_field(block, 14))
  use uid <- result.try(read_hex_field(block, 22))
  use gid <- result.try(read_hex_field(block, 30))
  use mtime <- result.try(read_hex_field(block, 46))
  use filesize <- result.try(read_hex_field(block, 54))
  use namesize <- result.try(read_hex_field(block, 94))

  Ok(ParsedHeader(
    mode: mode,
    uid: uid,
    gid: gid,
    mtime: mtime,
    filesize: filesize,
    namesize: namesize,
  ))
}

fn header_to_entry(
  header: ParsedHeader,
  name: String,
  body: BitArray,
  limits: limit.Limits,
) -> Result(entry.Entry, error.ArchiveError) {
  use <- bool.guard(
    when: string.byte_size(name) > limit.max_entry_name_bytes(limits),
    return: Error(error.ArchiveLimitExceeded(
      limit: "max_entry_name_bytes",
      actual: string.byte_size(name),
    )),
  )

  let file_type = int.bitwise_and(header.mode, 0o170000)
  let perm = int.bitwise_and(header.mode, 0o7777)

  use base <- result.try(case file_type {
    type_ if type_ == s_ifreg ->
      entry.file_checked(path: name, body: body)
      |> result.map_error(entry_error_to_archive_error(_, name))
    type_ if type_ == s_ifdir ->
      entry.directory_checked(path: name)
      |> result.map_error(entry_error_to_archive_error(_, name))
    type_ if type_ == s_iflnk -> {
      use target <- result.try(bytes_to_string(body))
      entry.symlink_checked(path: name, target: target)
      |> result.map_error(entry_error_to_archive_error(_, name))
    }
    other ->
      Error(error.ArchiveInvalid(
        message: "unsupported cpio mode " <> int.to_string(other),
      ))
  })

  let depth = entry.depth(entry.path(base))
  use <- bool.guard(
    when: depth > limit.max_entry_depth(limits),
    return: Error(error.ArchiveLimitExceeded(
      limit: "max_entry_depth",
      actual: depth,
    )),
  )

  Ok(
    base
    |> entry.with_mode(mode: perm)
    |> entry.with_owner(user_id: header.uid, group_id: header.gid)
    |> entry.with_modified_at(unix_seconds: header.mtime),
  )
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

fn encode_entry(value: entry.Entry) -> Result(BitArray, error.ArchiveError) {
  let kind = entry.kind(value)
  use <- bool.guard(
    when: kind == entry.Hardlink,
    return: Error(error.ArchiveEntryRejected(
      path: entry.to_string(entry.path(value)),
      reason: "cpio newc cannot represent hard links",
    )),
  )

  let path = entry.to_string(entry.path(value))
  let name_bytes = bit_array.from_string(path)
  let name_size = bit_array.byte_size(name_bytes) + 1
  let metadata = entry.metadata(value)

  let #(mode_bits, body) = case kind {
    entry.File -> #(s_ifreg, entry.body(value))
    entry.Directory -> #(s_ifdir, <<>>)
    entry.Symlink -> {
      let target = case entry.link_target(value) {
        Some(t) -> t
        None -> ""
      }
      #(s_iflnk, bit_array.from_string(target))
    }
    entry.Hardlink -> #(s_ifreg, entry.body(value))
  }

  let mode = int.bitwise_or(mode_bits, entry.mode(metadata))
  let body_size = bit_array.byte_size(body)
  let uid = entry.user_id(metadata)
  let gid = entry.group_id(metadata)
  let mtime = entry.modified_at_unix(metadata)

  // newc encodes every integer field as 8 ASCII hex digits, capping
  // each at 0xFFFFFFFF.  Reject larger values up-front so we never
  // silently emit a header whose decoded fields disagree with the
  // logical entry.
  use _ <- result.try(check_hex_field(mode, "mode"))
  use _ <- result.try(check_hex_field(uid, "uid"))
  use _ <- result.try(check_hex_field(gid, "gid"))
  use _ <- result.try(check_hex_field(mtime, "mtime"))
  use _ <- result.try(check_hex_field(body_size, "filesize"))
  use _ <- result.try(check_hex_field(name_size, "namesize"))

  let header =
    build_header(
      ino: 0,
      mode: mode,
      uid: uid,
      gid: gid,
      nlink: case kind == entry.Directory {
        True -> 2
        False -> 1
      },
      mtime: mtime,
      filesize: body_size,
      namesize: name_size,
    )

  let header_with_name =
    bit_array.concat([
      header,
      name_bytes,
      <<0>>,
      align_padding(header_size + name_size),
    ])

  let body_with_padding = bit_array.concat([body, align_padding(body_size)])

  Ok(bit_array.concat([header_with_name, body_with_padding]))
}

const newc_field_max: Int = 0xFFFFFFFF

fn check_hex_field(value: Int, field: String) -> Result(Nil, error.ArchiveError) {
  case value < 0 || value > newc_field_max {
    True ->
      Error(error.ArchiveFieldOverflow(
        field: "cpio-newc " <> field,
        value: value,
        max: newc_field_max,
      ))
    False -> Ok(Nil)
  }
}

fn trailer_record() -> BitArray {
  let name_bytes = bit_array.from_string(trailer_name)
  let name_size = bit_array.byte_size(name_bytes) + 1
  let header =
    build_header(
      ino: 0,
      mode: 0,
      uid: 0,
      gid: 0,
      nlink: 1,
      mtime: 0,
      filesize: 0,
      namesize: name_size,
    )
  bit_array.concat([
    header,
    name_bytes,
    <<0>>,
    align_padding(header_size + name_size),
  ])
}

fn build_header(
  ino ino: Int,
  mode mode: Int,
  uid uid: Int,
  gid gid: Int,
  nlink nlink: Int,
  mtime mtime: Int,
  filesize filesize: Int,
  namesize namesize: Int,
) -> BitArray {
  bit_array.concat([
    bit_array.from_string(magic_newc),
    hex_field(ino),
    hex_field(mode),
    hex_field(uid),
    hex_field(gid),
    hex_field(nlink),
    hex_field(mtime),
    hex_field(filesize),
    hex_field(0),
    hex_field(0),
    hex_field(0),
    hex_field(0),
    hex_field(namesize),
    hex_field(0),
  ])
}

fn hex_field(value: Int) -> BitArray {
  hex_digits(value, 8)
}

fn hex_digits(value: Int, width: Int) -> BitArray {
  hex_digits_loop(value, width, <<>>)
}

fn hex_digits_loop(value: Int, remaining: Int, acc: BitArray) -> BitArray {
  case remaining {
    0 -> acc
    _ -> {
      let digit = int.bitwise_and(value, 15)
      let next = int.bitwise_shift_right(value, 4)
      let ch = case digit < 10 {
        True -> 0x30 + digit
        False -> 0x61 + { digit - 10 }
      }
      hex_digits_loop(next, remaining - 1, <<ch, acc:bits>>)
    }
  }
}

fn align_padding(position: Int) -> BitArray {
  let aligned = pad_to_align(position)
  byte_repeat(0, aligned - position)
}

fn pad_to_align(position: Int) -> Int {
  case position % align {
    0 -> position
    rem -> position + { align - rem }
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

fn slice_or_error(
  block: BitArray,
  offset: Int,
  width: Int,
) -> Result(BitArray, error.ArchiveError) {
  case bit_array.slice(block, offset, width) {
    Ok(value) -> Ok(value)
    Error(_) -> Error(error.ArchiveInvalid(message: "cpio field out of bounds"))
  }
}

fn read_hex_field(
  block: BitArray,
  offset: Int,
) -> Result(Int, error.ArchiveError) {
  use slice <- result.try(slice_or_error(block, offset, 8))
  parse_hex(slice, 0)
}

fn parse_hex(bytes: BitArray, acc: Int) -> Result(Int, error.ArchiveError) {
  case bytes {
    <<>> -> Ok(acc)
    <<b, rest:bytes>> -> {
      case hex_value(b) {
        Ok(value) -> parse_hex(rest, acc * 16 + value)
        Error(_) ->
          Error(error.ArchiveInvalid(message: "invalid hex byte in cpio header"))
      }
    }
    _ -> Ok(acc)
  }
}

fn hex_value(byte: Int) -> Result(Int, Nil) {
  case byte {
    n if n >= 0x30 && n <= 0x39 -> Ok(n - 0x30)
    n if n >= 0x41 && n <= 0x46 -> Ok(n - 0x41 + 10)
    n if n >= 0x61 && n <= 0x66 -> Ok(n - 0x61 + 10)
    _ -> Error(Nil)
  }
}

fn bytes_to_string(bytes: BitArray) -> Result(String, error.ArchiveError) {
  case bit_array.to_string(bytes) {
    Ok(value) -> Ok(value)
    Error(_) ->
      Error(error.ArchiveInvalid(message: "non-UTF-8 string in cpio header"))
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
