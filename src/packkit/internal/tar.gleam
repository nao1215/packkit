//// USTAR (POSIX 1003.1-1988) tar archive encoder and decoder.
////
//// The implementation is target-neutral and supports regular files,
//// directories, symbolic links, and hard links.  The encoder rejects
//// names longer than the USTAR `prefix`/`name` split allows with a
//// typed archive error.  The decoder additionally consumes GNU
//// `LongName`/`LongLink` extension entries (typeflags `L` and `K`),
//// PAX extended attribute headers (`x` and `g`) — extracting the
//// `path` / `linkpath` records so files emitted by
//// `tar --format=pax` keep their full path past the USTAR 100-char
//// limit — and skips the other PAX attribute keys.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import packkit/archive
import packkit/internal/bytes
import packkit/internal/entry
import packkit/limit

const block_size: Int = 512

const name_size: Int = 100

const prefix_size: Int = 155

const linkname_size: Int = 100

/// Encode a logical archive to a USTAR byte stream.
pub fn encode(
  archive archive_value: archive.Archive,
) -> Result(BitArray, archive.ArchiveError) {
  use _ <- result.try(entry.reject_comment(archive_value))
  archive_value.entries
  |> list.try_map(encode_entry)
  |> result.map(fn(blocks) {
    [bit_array.concat(blocks), end_marker()]
    |> bit_array.concat
  })
}

/// Decode a USTAR byte stream into a logical archive using the supplied
/// resource limits.
pub fn decode_with_limits(
  bytes bytes: BitArray,
  limits limits: limit.Limits,
) -> Result(archive.Archive, archive.ArchiveError) {
  use _ <- result.try(entry.check_input(bytes, limits))

  decode_loop(bytes, [], 0, limits)
  |> result.try(entry.finish(_, archive.Tar, limits))
}

type PendingOverride {
  PendingOverride(name: String, linkname: String)
}

fn no_pending() -> PendingOverride {
  PendingOverride(name: "", linkname: "")
}

fn decode_loop(
  bytes: BitArray,
  acc: List(archive.Entry),
  count: Int,
  limits: limit.Limits,
) -> Result(List(archive.Entry), archive.ArchiveError) {
  decode_loop_with_pending(bytes, acc, count, limits, no_pending())
}

fn decode_loop_with_pending(
  bytes: BitArray,
  acc: List(archive.Entry),
  count: Int,
  limits: limit.Limits,
  pending: PendingOverride,
) -> Result(List(archive.Entry), archive.ArchiveError) {
  use header_bits <- result.try(case bytes {
    <<header_bits:bytes-size(block_size), _:bytes>> -> Ok(header_bits)
    _ ->
      Error(archive.InvalidData(
        message: "tar stream ended before terminator blocks",
      ))
  })
  // POSIX 1003.1 requires two consecutive zero blocks at end-of-archive;
  // a single zero block followed by truncation is malformed.
  use <- bool.lazy_guard(when: bytes.all_zero(header_bits), return: fn() {
    verify_double_zero_terminator(bytes, acc)
  })
  use header <- result.try(parse_header(header_bits))
  let total_advance = block_size + round_up_to_block(header.size)
  case bytes {
    <<_:bytes-size(total_advance), rest:bytes>> ->
      dispatch_typeflag(bytes, rest, acc, count, limits, pending, header)
    _ ->
      Error(archive.InvalidData(
        message: "tar entry body extends beyond the input",
      ))
  }
}

fn dispatch_typeflag(
  bytes: BitArray,
  rest: BitArray,
  acc: List(archive.Entry),
  count: Int,
  limits: limit.Limits,
  pending: PendingOverride,
  header: ParsedHeader,
) -> Result(List(archive.Entry), archive.ArchiveError) {
  case header.typeflag {
    // GNU LongName ('L'): body holds the next entry's name.
    0x4C -> {
      use long_name <- result.try(read_string_body(
        bytes,
        block_size,
        header.size,
        "GNU long name",
      ))
      decode_loop_with_pending(
        rest,
        acc,
        count,
        limits,
        PendingOverride(..pending, name: long_name),
      )
    }
    // GNU LongLink ('K'): body holds the next entry's linkname.
    0x4B -> {
      use long_link <- result.try(read_string_body(
        bytes,
        block_size,
        header.size,
        "GNU long linkname",
      ))
      decode_loop_with_pending(
        rest,
        acc,
        count,
        limits,
        PendingOverride(..pending, linkname: long_link),
      )
    }
    // PAX extended attribute headers ('x' = local, 'g' = global).
    // Each header body is a sequence of "<length> <key>=<value>\n"
    // records (POSIX 1003.1).  We parse the "path" and "linkpath"
    // keys — the others (mtime, atime, size, charset, …) don't
    // change which bytes get emitted so they're still skipped.
    // 'g' attributes are supposed to apply across entries; for now
    // we only carry them through to the immediately-following
    // entry just like 'x'.
    0x78 | 0x67 -> {
      use pax_body <- result.try(read_pax_body(bytes, block_size, header.size))
      let pending = apply_pax_records(pending, pax_body)
      decode_loop_with_pending(rest, acc, count, limits, pending)
    }
    _ -> {
      let merged_header = apply_pending(header, pending)
      use _ <- result.try(entry.check_member_limit(count + 1, limits))
      use entry_value <- result.try(header_to_entry(
        merged_header,
        bytes,
        limits,
      ))
      decode_loop_with_pending(
        rest,
        [entry_value, ..acc],
        count + 1,
        limits,
        no_pending(),
      )
    }
  }
}

fn apply_pending(
  header: ParsedHeader,
  pending: PendingOverride,
) -> ParsedHeader {
  let name = case pending.name {
    "" -> header.name
    n -> n
  }
  let linkname = case pending.linkname {
    "" -> header.linkname
    l -> l
  }
  ParsedHeader(..header, name: name, linkname: linkname)
}

/// Read the body of a PAX 'x' / 'g' extended-attribute header.
/// Returns the raw bytes; the caller is responsible for parsing
/// the "<length> <key>=<value>\n" records inside.
fn read_pax_body(
  source: BitArray,
  start: Int,
  size: Int,
) -> Result(BitArray, archive.ArchiveError) {
  bytes.slice(source, start, size)
  |> result.replace_error(archive.InvalidData(
    message: "truncated tar PAX extended header",
  ))
}

/// Walk a PAX extended-header body and lift the keys we know how
/// to use ("path" overrides the next entry's name, "linkpath"
/// overrides the next entry's linkname).  Records with other keys
/// are silently dropped — they don't change which bytes the entry
/// holds, only how POSIX-aware tools display its metadata.
fn apply_pax_records(
  pending: PendingOverride,
  body: BitArray,
) -> PendingOverride {
  case extract_pax_record(body) {
    Error(_) -> pending
    Ok(#(key, value, rest)) -> {
      let pending = case key {
        "path" -> PendingOverride(..pending, name: value)
        "linkpath" -> PendingOverride(..pending, linkname: value)
        _ -> pending
      }
      apply_pax_records(pending, rest)
    }
  }
}

/// Parse one "<length> <key>=<value>\n" PAX record off the front of
/// `body` and return (key, value, rest). The length counts bytes, and
/// covers the digits, the space and the newline.
fn extract_pax_record(
  body: BitArray,
) -> Result(#(String, String, BitArray), Nil) {
  use #(length, digits) <- result.try(pax_length(body, 0, 0))
  let inner_size = length - digits - 2
  use <- bool.guard(when: inner_size <= 0, return: Error(Nil))
  case body {
    <<
      _:bytes-size(digits),
      " ",
      inner:bytes-size(inner_size),
      "\n",
      rest:bytes,
    >> -> {
      use #(key, value) <- result.try(
        bit_array.to_string(inner) |> result.try(string.split_once(_, "=")),
      )
      Ok(#(key, value, rest))
    }
    _ -> Error(Nil)
  }
}

// Reads the decimal length before the first space, and the number of
// digits it took.
fn pax_length(
  body: BitArray,
  acc: Int,
  digits: Int,
) -> Result(#(Int, Int), Nil) {
  case body {
    <<" ", _:bytes>> if digits > 0 -> Ok(#(acc, digits))
    <<digit, rest:bytes>> if digit >= 0x30 && digit <= 0x39 ->
      pax_length(rest, acc * 10 + digit - 0x30, digits + 1)
    _ -> Error(Nil)
  }
}

fn read_string_body(
  bytes: BitArray,
  start: Int,
  size: Int,
  label: String,
) -> Result(String, archive.ArchiveError) {
  case bytes {
    <<_:bytes-size(start), chunk:bytes-size(size), _:bytes>> ->
      bit_array.to_string(bytes.strip_trailing_nul(chunk))
      |> result.replace_error(archive.InvalidData(
        message: "tar " <> label <> " is not valid UTF-8",
      ))
    _ -> Error(archive.InvalidData(message: "truncated tar " <> label))
  }
}

type ParsedHeader {
  ParsedHeader(
    name: String,
    mode: Int,
    uid: Int,
    gid: Int,
    size: Int,
    mtime: Int,
    typeflag: Int,
    linkname: String,
  )
}

fn parse_header(block: BitArray) -> Result(ParsedHeader, archive.ArchiveError) {
  use _ <- result.try(verify_checksum(block))

  use raw_name <- result.try(read_string_field(block, 0, name_size))
  use mode <- result.try(read_octal_field(block, 100, 8))
  use uid <- result.try(read_octal_field(block, 108, 8))
  use gid <- result.try(read_octal_field(block, 116, 8))
  use size <- result.try(read_octal_field(block, 124, 12))
  use mtime <- result.try(read_octal_field(block, 136, 12))
  use typeflag <- result.try(read_byte(block, 156))
  use linkname <- result.try(read_string_field(block, 157, linkname_size))
  use prefix <- result.try(read_string_field(block, 345, prefix_size))

  let name = case prefix {
    "" -> raw_name
    _ -> prefix <> "/" <> raw_name
  }

  Ok(ParsedHeader(
    name: name,
    mode: mode,
    uid: uid,
    gid: gid,
    size: size,
    mtime: mtime,
    typeflag: typeflag,
    linkname: linkname,
  ))
}

fn header_to_entry(
  header: ParsedHeader,
  bytes: BitArray,
  limits: limit.Limits,
) -> Result(archive.Entry, archive.ArchiveError) {
  use <- bool.guard(
    when: string.byte_size(header.name) > limits.max_entry_name_bytes,
    return: Error(archive.LimitExceeded(
      limit: "max_entry_name_bytes",
      actual: string.byte_size(header.name),
    )),
  )

  use base_entry <- result.try(case header.typeflag {
    0x30 -> regular_entry(header, bytes)
    0x00 -> regular_entry(header, bytes)
    0x35 -> directory_entry(header)
    0x32 ->
      link_entry(header, fn(p, t) { entry.symlink_checked(path: p, target: t) })
    0x31 ->
      link_entry(header, fn(p, t) { entry.hardlink_checked(path: p, target: t) })
    other ->
      Error(archive.InvalidData(
        message: "unsupported tar typeflag " <> int.to_string(other),
      ))
  })

  let name_for_depth = entry.strip_trailing_slash(header.name)
  case entry.check_path(name_for_depth) {
    Ok(Nil) ->
      case entry.depth(name_for_depth) > limits.max_entry_depth {
        True ->
          Error(archive.LimitExceeded(
            limit: "max_entry_depth",
            actual: entry.depth(name_for_depth),
          ))
        False -> Ok(Nil)
      }
    Error(_) -> Ok(Nil)
  }
  |> result.map(fn(_) {
    archive.Entry(
      ..base_entry,
      mode: header.mode,
      user_id: header.uid,
      group_id: header.gid,
      modified_at: header.mtime,
    )
  })
}

fn regular_entry(
  header: ParsedHeader,
  bytes: BitArray,
) -> Result(archive.Entry, archive.ArchiveError) {
  let body = case bit_array.slice(bytes, block_size, header.size) {
    Ok(body) -> body
    Error(_) -> <<>>
  }
  entry.file_checked(path: header.name, body: body)
  |> result.map_error(entry.to_archive_error(_, header.name))
}

fn directory_entry(
  header: ParsedHeader,
) -> Result(archive.Entry, archive.ArchiveError) {
  entry.directory_checked(path: entry.strip_trailing_slash(header.name))
  |> result.map_error(entry.to_archive_error(_, header.name))
}

fn link_entry(
  header: ParsedHeader,
  builder: fn(String, String) -> Result(archive.Entry, entry.EntryError),
) -> Result(archive.Entry, archive.ArchiveError) {
  builder(header.name, header.linkname)
  |> result.map_error(entry.to_archive_error(_, header.name))
}

fn verify_checksum(block: BitArray) -> Result(Nil, archive.ArchiveError) {
  use stored <- result.try(read_checksum_field(block))
  let computed = compute_checksum(block)
  case stored == computed {
    True -> Ok(Nil)
    False -> Error(archive.InvalidData(message: "tar header checksum mismatch"))
  }
}

fn read_checksum_field(block: BitArray) -> Result(Int, archive.ArchiveError) {
  read_octal_field(block, 148, 8)
}

fn compute_checksum(block: BitArray) -> Int {
  sum_with_checksum_blanked(block, 0, 0)
}

fn sum_with_checksum_blanked(block: BitArray, position: Int, acc: Int) -> Int {
  case block {
    <<>> -> acc
    <<b, rest:bytes>> -> {
      let contribution = case position >= 148 && position < 156 {
        True -> 0x20
        False -> b
      }
      sum_with_checksum_blanked(rest, position + 1, acc + contribution)
    }
    _ -> acc
  }
}

fn encode_entry(
  entry_value: archive.Entry,
) -> Result(BitArray, archive.ArchiveError) {
  use header <- result.try(build_header(entry_value))
  let body = entry.body(entry_value)
  let body_blocks = pad_to_block(body)
  Ok(bit_array.concat([header, body_blocks]))
}

fn build_header(
  value: archive.Entry,
) -> Result(BitArray, archive.ArchiveError) {
  let kind = value.kind
  let path = value.path

  use #(name_field, prefix_field) <- result.try(split_name_field(path, kind))

  let typeflag = case kind {
    archive.File(_) -> 0x30
    archive.Directory -> 0x35
    archive.Symlink(_) -> 0x32
    archive.Hardlink(_) -> 0x31
  }

  let size = bit_array.byte_size(entry.body(value))

  let linkname = case entry.link_target(value) {
    Some(target) -> target
    None -> ""
  }

  use linkname_field <- result.try(fit_field(
    linkname,
    linkname_size,
    kind: "linkname",
  ))

  // USTAR encodes integers as zero-padded octal terminated by NUL.
  // A `width=8` field thus holds 7 octal digits → max 2^21-1; a
  // `width=12` field holds 11 octal digits → max 2^33-1.  Reject
  // overflow instead of silently dropping high bits.
  use mode_field <- result.try(checked_octal_field(value.mode, 8, "mode"))
  use uid_field <- result.try(checked_octal_field(value.user_id, 8, "uid"))
  use gid_field <- result.try(checked_octal_field(value.group_id, 8, "gid"))
  use size_field <- result.try(checked_octal_field(size, 12, "size"))
  use mtime_field <- result.try(checked_octal_field(
    value.modified_at,
    12,
    "mtime",
  ))

  let before_checksum =
    bit_array.concat([
      name_field,
      mode_field,
      uid_field,
      gid_field,
      size_field,
      mtime_field,
    ])
  let after_checksum =
    bit_array.concat([
      <<typeflag>>,
      linkname_field,
      magic_field(),
      version_field(),
      uname_field(),
      gname_field(),
      devmajor_field(),
      devminor_field(),
      prefix_field,
      tail_padding(),
    ])
  let checksum_value =
    compute_checksum(<<
      before_checksum:bits,
      checksum_blank_field():bits,
      after_checksum:bits,
    >>)
  Ok(<<
    before_checksum:bits,
    checksum_value_field(checksum_value):bits,
    after_checksum:bits,
  >>)
}

fn split_name_field(
  path: String,
  kind: archive.EntryKind,
) -> Result(#(BitArray, BitArray), archive.ArchiveError) {
  let canonical = case kind {
    archive.Directory -> path <> "/"
    archive.File(_) | archive.Symlink(_) | archive.Hardlink(_) -> path
  }

  let canonical_bytes = bit_array.from_string(canonical)
  let size = bit_array.byte_size(canonical_bytes)

  case size <= name_size {
    True ->
      Ok(#(
        bytes.pad_end(canonical_bytes, name_size, 0),
        bytes.pad_end(<<>>, prefix_size, 0),
      ))
    False -> attempt_prefix_split(canonical, size)
  }
}

fn attempt_prefix_split(
  canonical: String,
  total_bytes: Int,
) -> Result(#(BitArray, BitArray), archive.ArchiveError) {
  case total_bytes > name_size + prefix_size + 1 {
    True ->
      Error(archive.EntryRejected(
        path: canonical,
        reason: "name longer than 256 bytes (USTAR limit)",
      ))
    False -> {
      let segments = string.split(canonical, "/")
      case find_prefix_split(segments) {
        Some(#(prefix, rest)) ->
          Ok(#(
            bytes.pad_end(bit_array.from_string(rest), name_size, 0),
            bytes.pad_end(bit_array.from_string(prefix), prefix_size, 0),
          ))
        None ->
          Error(archive.EntryRejected(
            path: canonical,
            reason: "no USTAR-compatible prefix/name split",
          ))
      }
    }
  }
}

fn find_prefix_split(segments: List(String)) -> Option(#(String, String)) {
  // Walk through every possible split between segments and pick the one
  // where both halves fit USTAR's prefix and name budgets.
  let total = list.length(segments)
  case total < 2 {
    True -> None
    False -> search_prefix_split(segments, total, 1, None)
  }
}

fn search_prefix_split(
  segments: List(String),
  total: Int,
  split_at: Int,
  best: Option(#(String, String)),
) -> Option(#(String, String)) {
  case split_at >= total {
    True -> best
    False -> {
      let #(left, right) = take_split(segments, split_at)
      let prefix = string.join(left, "/")
      let rest = string.join(right, "/")
      let fits =
        string.byte_size(prefix) <= prefix_size
        && string.byte_size(rest) <= name_size
        && string.byte_size(rest) > 0
      let next_best = case fits {
        True -> Some(#(prefix, rest))
        False -> best
      }
      search_prefix_split(segments, total, split_at + 1, next_best)
    }
  }
}

fn take_split(
  segments: List(String),
  split_at: Int,
) -> #(List(String), List(String)) {
  take_split_loop(segments, split_at, [])
}

fn take_split_loop(
  segments: List(String),
  remaining: Int,
  acc: List(String),
) -> #(List(String), List(String)) {
  case remaining, segments {
    0, _ -> #(list.reverse(acc), segments)
    _, [] -> #(list.reverse(acc), [])
    _, [head, ..tail] -> take_split_loop(tail, remaining - 1, [head, ..acc])
  }
}

fn fit_field(
  value: String,
  width: Int,
  kind kind: String,
) -> Result(BitArray, archive.ArchiveError) {
  let bytes = bit_array.from_string(value)
  case bit_array.byte_size(bytes) > width {
    True ->
      Error(archive.EntryRejected(
        path: value,
        reason: kind <> " longer than " <> int.to_string(width) <> " bytes",
      ))
    False -> Ok(bytes.pad_end(bytes, width, 0))
  }
}

fn octal_field(value: Int, width: Int) -> BitArray {
  // `width` covers the digit run plus the trailing NUL terminator that
  // USTAR specifies.
  let digit_width = width - 1
  let digits = to_octal_digits(value, digit_width)
  bit_array.concat([digits, <<0>>])
}

fn checked_octal_field(
  value: Int,
  width: Int,
  field: String,
) -> Result(BitArray, archive.ArchiveError) {
  let digit_width = width - 1
  let max_value = pow_int(8, digit_width) - 1
  case value < 0 || value > max_value {
    True ->
      Error(archive.FieldOverflow(
        field: "tar " <> field,
        value: value,
        max: max_value,
      ))
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

fn checksum_blank_field() -> BitArray {
  bytes.repeat(0x20, 8)
}

fn checksum_value_field(value: Int) -> BitArray {
  let digits = to_octal_digits(value, 6)
  bit_array.concat([digits, <<0, 0x20>>])
}

fn magic_field() -> BitArray {
  bit_array.from_string("ustar")
  |> bytes.pad_end(6, 0)
}

fn version_field() -> BitArray {
  bit_array.from_string("00")
}

fn uname_field() -> BitArray {
  bytes.repeat(0, 32)
}

fn gname_field() -> BitArray {
  bytes.repeat(0, 32)
}

fn devmajor_field() -> BitArray {
  octal_field(0, 8)
}

fn devminor_field() -> BitArray {
  octal_field(0, 8)
}

fn tail_padding() -> BitArray {
  bytes.repeat(0, 12)
}

fn end_marker() -> BitArray {
  bytes.repeat(0, block_size * 2)
}

fn pad_to_block(body: BitArray) -> BitArray {
  let size = bit_array.byte_size(body)
  let padded_size = round_up_to_block(size)
  let padding = padded_size - size
  bit_array.concat([body, bytes.repeat(0, padding)])
}

fn round_up_to_block(size: Int) -> Int {
  case size % block_size {
    0 -> size
    rem -> size + { block_size - rem }
  }
}

fn to_octal_digits(value: Int, digit_width: Int) -> BitArray {
  to_octal_digits_loop(value, digit_width, <<>>)
}

fn to_octal_digits_loop(value: Int, remaining: Int, acc: BitArray) -> BitArray {
  case remaining {
    0 -> acc
    _ -> {
      let digit = value % 8
      let next = value / 8
      let ch = 0x30 + digit
      to_octal_digits_loop(next, remaining - 1, <<ch, acc:bits>>)
    }
  }
}

fn read_string_field(
  block: BitArray,
  offset: Int,
  width: Int,
) -> Result(String, archive.ArchiveError) {
  case bit_array.slice(block, offset, width) {
    Error(_) ->
      Error(archive.InvalidData(message: "header field out of bounds"))
    Ok(slice) -> {
      let trimmed = bytes.strip_trailing_nul(slice)
      case bit_array.to_string(trimmed) {
        Ok(value) -> Ok(value)
        Error(_) ->
          Error(archive.InvalidData(
            message: "header field contains non-UTF-8 bytes",
          ))
      }
    }
  }
}

fn read_octal_field(
  block: BitArray,
  offset: Int,
  width: Int,
) -> Result(Int, archive.ArchiveError) {
  case bit_array.slice(block, offset, width) {
    Error(_) ->
      Error(archive.InvalidData(message: "header field out of bounds"))
    Ok(slice) -> parse_octal(slice, 0, False)
  }
}

fn parse_octal(
  bytes: BitArray,
  acc: Int,
  any_digit: Bool,
) -> Result(Int, archive.ArchiveError) {
  case bytes {
    <<>> ->
      case any_digit {
        True -> Ok(acc)
        False -> Ok(0)
      }
    <<b, rest:bytes>> ->
      case classify_octal_byte(b) {
        OctalDigit(d) -> parse_octal(rest, acc * 8 + d, True)
        OctalSpace -> parse_octal(rest, acc, any_digit)
        OctalTerminator ->
          case any_digit {
            True -> Ok(acc)
            False -> parse_octal(rest, acc, any_digit)
          }
        OctalInvalid ->
          Error(archive.InvalidData(message: "invalid octal byte in tar header"))
      }
    _ -> Ok(acc)
  }
}

type OctalClass {
  OctalDigit(Int)
  OctalSpace
  OctalTerminator
  OctalInvalid
}

fn classify_octal_byte(byte: Int) -> OctalClass {
  case byte {
    0 -> OctalTerminator
    0x20 -> OctalSpace
    n if n >= 0x30 && n <= 0x37 -> OctalDigit(n - 0x30)
    _ -> OctalInvalid
  }
}

fn read_byte(
  block: BitArray,
  offset: Int,
) -> Result(Int, archive.ArchiveError) {
  case bit_array.slice(block, offset, 1) {
    Ok(<<b>>) -> Ok(b)
    _ -> Error(archive.InvalidData(message: "header byte out of bounds"))
  }
}

fn verify_double_zero_terminator(
  bytes: BitArray,
  acc: List(archive.Entry),
) -> Result(List(archive.Entry), archive.ArchiveError) {
  case bit_array.slice(bytes, block_size, block_size) {
    Ok(second) ->
      case bytes.all_zero(second) {
        True -> Ok(acc)
        False ->
          Error(archive.InvalidData(
            message: "tar stream ended after a single zero block",
          ))
      }
    Error(_) ->
      Error(archive.InvalidData(
        message: "tar stream ended after a single zero block",
      ))
  }
}
