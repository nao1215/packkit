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
import gleam/result
import gleam/string
import packkit/archive
import packkit/internal/bytes
import packkit/internal/entry
import packkit/limit

const header_size: Int = 110

const magic_newc: String = "070701"

const magic_crc: String = "070702"

const trailer_name: String = "TRAILER!!!"

const align: Int = 4

const s_ifreg: Int = 0o100000

const s_ifdir: Int = 0o040000

const s_iflnk: Int = 0o120000

/// Encode the logical archive to a newc byte stream.
pub fn encode(
  archive archive_value: archive.Archive,
) -> Result(BitArray, archive.ArchiveError) {
  use _ <- result.try(entry.reject_comment(archive_value))
  archive_value.entries
  |> list.try_map(encode_entry)
  |> result.map(fn(blocks) {
    [bit_array.concat(blocks), trailer_record()]
    |> bit_array.concat
  })
}

/// Decode a newc byte stream using explicit limits.
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
  decode_loop(bytes, [], 0, limits)
  |> result.try(entry.finish(_, archive.Cpio, limits))
}

fn decode_loop(
  bytes: BitArray,
  acc: List(archive.Entry),
  count: Int,
  limits: limit.Limits,
) -> Result(List(archive.Entry), archive.ArchiveError) {
  use #(header_bits, after_header) <- result.try(case bytes {
    <<header_bits:bytes-size(header_size), after_header:bytes>> ->
      Ok(#(header_bits, after_header))
    _ -> Error(archive.InvalidData(message: "cpio header truncated"))
  })
  use header <- result.try(parse_header(header_bits))

  // The name and the body are each padded to a multiple of 4 bytes,
  // counted from the start of the header.
  let name_size = header.namesize
  let name_padding =
    pad_to_align(header_size + name_size) - header_size - name_size
  let body_size = header.filesize
  let body_padding = pad_to_align(body_size) - body_size
  use #(name_bits, body, rest) <- result.try(case after_header {
    <<
      name_bits:bytes-size(name_size),
      _:bytes-size(name_padding),
      body:bytes-size(body_size),
      rest:bytes,
    >> -> Ok(#(name_bits, body, skip(rest, body_padding)))
    _ -> Error(archive.InvalidData(message: "cpio entry truncated"))
  })
  use name <- result.try(bytes_to_string(bytes.strip_trailing_nul(name_bits)))

  case name == trailer_name {
    True -> Ok(acc)
    False -> {
      use _ <- result.try(entry.check_member_limit(count + 1, limits))
      use entry_value <- result.try(header_to_entry(header, name, body, limits))
      decode_loop(rest, [entry_value, ..acc], count + 1, limits)
    }
  }
}

// Drops up to `count` padding bytes. The padding after the last body may
// be missing; the reader then fails on the missing trailer.
fn skip(bytes: BitArray, count: Int) -> BitArray {
  case bytes {
    <<_:bytes-size(count), rest:bytes>> -> rest
    _ -> <<>>
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

fn parse_header(block: BitArray) -> Result(ParsedHeader, archive.ArchiveError) {
  use magic_bits <- result.try(slice_or_error(block, 0, 6))
  use magic <- result.try(bytes_to_string(magic_bits))
  // newc (070701) and crc (070702) share the same on-disk layout;
  // the only difference is that crc carries a 32-bit CRC of the
  // file body in the `checksum` field that newc leaves as zero.
  // We don't verify the body checksum, so accepting both magics
  // here lets `cpio -H crc` archives round-trip end-to-end.
  use <- bool.guard(
    when: magic != magic_newc && magic != magic_crc,
    return: Error(archive.InvalidData(message: "not a newc/crc cpio magic")),
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
) -> Result(archive.Entry, archive.ArchiveError) {
  use <- bool.guard(
    when: string.byte_size(name) > limits.max_entry_name_bytes,
    return: Error(archive.LimitExceeded(
      limit: "max_entry_name_bytes",
      actual: string.byte_size(name),
    )),
  )

  let file_type = int.bitwise_and(header.mode, 0o170000)
  let perm = int.bitwise_and(header.mode, 0o7777)

  use base <- result.try(case file_type {
    type_ if type_ == s_ifreg ->
      entry.file_checked(path: name, body: body)
      |> result.map_error(entry.to_archive_error(_, name))
    type_ if type_ == s_ifdir ->
      entry.directory_checked(path: name)
      |> result.map_error(entry.to_archive_error(_, name))
    type_ if type_ == s_iflnk -> {
      use target <- result.try(bytes_to_string(body))
      entry.symlink_checked(path: name, target: target)
      |> result.map_error(entry.to_archive_error(_, name))
    }
    other ->
      Error(archive.InvalidData(
        message: "unsupported cpio mode " <> int.to_string(other),
      ))
  })

  let depth = entry.depth(base.path)
  use <- bool.guard(
    when: depth > limits.max_entry_depth,
    return: Error(archive.LimitExceeded(limit: "max_entry_depth", actual: depth)),
  )

  Ok(
    archive.Entry(
      ..base,
      mode: perm,
      user_id: header.uid,
      group_id: header.gid,
      modified_at: header.mtime,
    ),
  )
}

fn encode_entry(
  value: archive.Entry,
) -> Result(BitArray, archive.ArchiveError) {
  use #(mode_bits, body) <- result.try(case value.kind {
    archive.File(body) -> Ok(#(s_ifreg, body))
    archive.Directory -> Ok(#(s_ifdir, <<>>))
    archive.Symlink(target) -> Ok(#(s_iflnk, bit_array.from_string(target)))
    archive.Hardlink(_) ->
      Error(archive.EntryRejected(
        path: value.path,
        reason: "cpio newc cannot represent hard links",
      ))
  })

  let path = value.path
  let name_bytes = bit_array.from_string(path)
  let name_size = bit_array.byte_size(name_bytes) + 1

  // The kind decides the file type bits, so only the permission bits of
  // the entry's mode are kept.  A mode read from ZIP still carries type
  // bits such as 0o100000.
  let mode = int.bitwise_or(mode_bits, int.bitwise_and(value.mode, 0o7777))
  let body_size = bit_array.byte_size(body)
  let uid = value.user_id
  let gid = value.group_id
  let mtime = value.modified_at

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
      nlink: case value.kind == archive.Directory {
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

fn check_hex_field(
  value: Int,
  field: String,
) -> Result(Nil, archive.ArchiveError) {
  case value < 0 || value > newc_field_max {
    True ->
      Error(archive.FieldOverflow(
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
  bytes.repeat(0, aligned - position)
}

fn pad_to_align(position: Int) -> Int {
  case position % align {
    0 -> position
    rem -> position + { align - rem }
  }
}

fn slice_or_error(
  block: BitArray,
  offset: Int,
  width: Int,
) -> Result(BitArray, archive.ArchiveError) {
  bytes.slice(block, offset, width)
  |> result.replace_error(archive.InvalidData(
    message: "cpio field out of bounds",
  ))
}

fn read_hex_field(
  block: BitArray,
  offset: Int,
) -> Result(Int, archive.ArchiveError) {
  use slice <- result.try(slice_or_error(block, offset, 8))
  parse_hex(slice, 0)
}

fn parse_hex(bytes: BitArray, acc: Int) -> Result(Int, archive.ArchiveError) {
  case bytes {
    <<>> -> Ok(acc)
    <<b, rest:bytes>> -> {
      case hex_value(b) {
        Ok(value) -> parse_hex(rest, acc * 16 + value)
        Error(_) ->
          Error(archive.InvalidData(message: "invalid hex byte in cpio header"))
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

fn bytes_to_string(bytes: BitArray) -> Result(String, archive.ArchiveError) {
  case bit_array.to_string(bytes) {
    Ok(value) -> Ok(value)
    Error(_) ->
      Error(archive.InvalidData(message: "non-UTF-8 string in cpio header"))
  }
}
