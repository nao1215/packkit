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
import packkit/archive as archives
import packkit/entry
import packkit/error
import packkit/limit

const block_size: Int = 512

const name_size: Int = 100

const prefix_size: Int = 155

const linkname_size: Int = 100

/// Tar archive format marker.
pub fn format() -> archives.ArchiveFormat {
  archives.tar()
}

/// Create an empty tar archive value.
pub fn new() -> archives.Archive {
  archives.new(format: format())
}

/// Add a regular file after checked path validation.
pub fn add_file_checked(
  archive archive_value: archives.Archive,
  path path: String,
  body body: BitArray,
) -> Result(archives.Archive, entry.EntryError) {
  case entry.file_checked(path: path, body: body) {
    Ok(value) -> Ok(archives.add(archive_value, entry: value))
    Error(err) -> Error(err)
  }
}

/// Panicking counterpart of `add_file_checked`.
pub fn add_file(
  archive archive_value: archives.Archive,
  path path: String,
  body body: BitArray,
) -> archives.Archive {
  archives.add(archive_value, entry: entry.file(path: path, body: body))
}

/// Add a directory after checked path validation.
pub fn add_directory_checked(
  archive archive_value: archives.Archive,
  path path: String,
) -> Result(archives.Archive, entry.EntryError) {
  case entry.directory_checked(path) {
    Ok(value) -> Ok(archives.add(archive_value, entry: value))
    Error(err) -> Error(err)
  }
}

/// Panicking counterpart of `add_directory_checked`.
pub fn add_directory(
  archive archive_value: archives.Archive,
  path path: String,
) -> archives.Archive {
  archives.add(archive_value, entry: entry.directory(path))
}

/// Add a symbolic link after checked path validation.
pub fn add_symlink_checked(
  archive archive_value: archives.Archive,
  path path: String,
  target target: String,
) -> Result(archives.Archive, entry.EntryError) {
  case entry.symlink_checked(path: path, target: target) {
    Ok(value) -> Ok(archives.add(archive_value, entry: value))
    Error(err) -> Error(err)
  }
}

/// Panicking counterpart of `add_symlink_checked`.
pub fn add_symlink(
  archive archive_value: archives.Archive,
  path path: String,
  target target: String,
) -> archives.Archive {
  archives.add(archive_value, entry: entry.symlink(path: path, target: target))
}

/// Encode a logical archive to a USTAR byte stream.
pub fn encode(
  archive archive_value: archives.Archive,
) -> Result(BitArray, error.ArchiveError) {
  use _ <- result.try(reject_comment(archive_value))
  archive_value
  |> archives.entries
  |> list.try_map(encode_entry)
  |> result.map(fn(blocks) {
    [bit_array.concat(blocks), end_marker()]
    |> bit_array.concat
  })
}

fn reject_comment(
  archive_value: archives.Archive,
) -> Result(Nil, error.ArchiveError) {
  case archives.comment(archive_value) {
    None -> Ok(Nil)
    Some(_) -> Error(error.ArchiveCommentUnsupported(format: "tar"))
  }
}

/// Decode a USTAR byte stream into a logical archive using the default
/// resource limits.
pub fn decode(
  bytes bytes: BitArray,
) -> Result(archives.Archive, error.ArchiveError) {
  decode_with_limits(bytes: bytes, limits: limit.default())
}

/// Decode a USTAR byte stream into a logical archive using the supplied
/// resource limits.
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

type PendingOverride {
  PendingOverride(name: String, linkname: String)
}

fn no_pending() -> PendingOverride {
  PendingOverride(name: "", linkname: "")
}

fn decode_loop(
  bytes: BitArray,
  acc: List(entry.Entry),
  count: Int,
  limits: limit.Limits,
) -> Result(List(entry.Entry), error.ArchiveError) {
  decode_loop_with_pending(bytes, acc, count, limits, no_pending())
}

fn decode_loop_with_pending(
  bytes: BitArray,
  acc: List(entry.Entry),
  count: Int,
  limits: limit.Limits,
  pending: PendingOverride,
) -> Result(List(entry.Entry), error.ArchiveError) {
  use <- bool.guard(
    when: bit_array.byte_size(bytes) < block_size,
    return: Error(error.ArchiveInvalid(
      message: "tar stream ended before terminator blocks",
    )),
  )
  let assert Ok(header_bits) = bit_array.slice(bytes, 0, block_size)
  // POSIX 1003.1 requires two consecutive zero blocks at end-of-archive;
  // a single zero block followed by truncation is malformed.
  use <- bool.lazy_guard(when: is_zero_block(header_bits), return: fn() {
    verify_double_zero_terminator(bytes, acc)
  })
  use header <- result.try(parse_header(header_bits))
  let body_padded = round_up_to_block(header.size)
  let total_advance = block_size + body_padded
  use <- bool.guard(
    when: bit_array.byte_size(bytes) < total_advance,
    return: Error(error.ArchiveInvalid(
      message: "tar entry body extends beyond the input",
    )),
  )
  let assert Ok(rest) =
    bit_array.slice(
      bytes,
      total_advance,
      bit_array.byte_size(bytes) - total_advance,
    )
  dispatch_typeflag(bytes, rest, acc, count, limits, pending, header)
}

fn dispatch_typeflag(
  bytes: BitArray,
  rest: BitArray,
  acc: List(entry.Entry),
  count: Int,
  limits: limit.Limits,
  pending: PendingOverride,
  header: ParsedHeader,
) -> Result(List(entry.Entry), error.ArchiveError) {
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
      use _ <- result.try(check_member_limit(count + 1, limits))
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

fn apply_pending(header: ParsedHeader, pending: PendingOverride) -> ParsedHeader {
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
  bytes: BitArray,
  start: Int,
  size: Int,
) -> Result(BitArray, error.ArchiveError) {
  case bit_array.slice(bytes, start, size) {
    Ok(chunk) -> Ok(chunk)
    Error(_) ->
      Error(error.ArchiveInvalid(message: "truncated tar PAX extended header"))
  }
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
  case bit_array.to_string(body) {
    Ok(text) -> apply_pax_records_loop(pending, text)
    Error(_) -> pending
  }
}

fn apply_pax_records_loop(
  pending: PendingOverride,
  text: String,
) -> PendingOverride {
  case extract_pax_record(text) {
    Error(_) -> pending
    Ok(#(key, value, rest)) -> {
      let pending = case key {
        "path" -> PendingOverride(..pending, name: value)
        "linkpath" -> PendingOverride(..pending, linkname: value)
        _ -> pending
      }
      apply_pax_records_loop(pending, rest)
    }
  }
}

/// Parse one "<length> <key>=<value>\n" PAX record off the front
/// of `text` and return (key, value, remaining_text).
fn extract_pax_record(text: String) -> Result(#(String, String, String), Nil) {
  use #(length_str, after_space) <- result.try(string.split_once(text, " "))
  use length <- result.try(int.parse(length_str))
  // The length is total bytes including the leading digits, the
  // space, and the trailing \n.  We can recover the inner part
  // as `length - (len(length_str) + 1) - 1` characters because
  // length covers <length_str><space><key=value><\n>.
  let head_size = string.length(length_str) + 1
  let inner_size = length - head_size - 1
  use <- bool.guard(when: inner_size < 0, return: Error(Nil))
  case string.slice(after_space, 0, inner_size) {
    "" -> Error(Nil)
    body -> {
      use #(key, value) <- result.try(string.split_once(body, "="))
      let rest =
        string.slice(after_space, inner_size + 1, string.length(after_space))
      Ok(#(key, value, rest))
    }
  }
}

fn read_string_body(
  bytes: BitArray,
  start: Int,
  size: Int,
  label: String,
) -> Result(String, error.ArchiveError) {
  case bit_array.slice(bytes, start, size) {
    Ok(chunk) -> {
      // Drop a trailing NUL if present.
      let trimmed_size = trim_trailing_nul_size(chunk, size)
      let assert Ok(name_bits) = bit_array.slice(chunk, 0, trimmed_size)
      case bit_array.to_string(name_bits) {
        Ok(value) -> Ok(value)
        Error(_) ->
          Error(error.ArchiveInvalid(
            message: "tar " <> label <> " is not valid UTF-8",
          ))
      }
    }
    Error(_) -> Error(error.ArchiveInvalid(message: "truncated tar " <> label))
  }
}

fn trim_trailing_nul_size(bytes: BitArray, size: Int) -> Int {
  case size {
    0 -> 0
    n ->
      case bit_array.slice(bytes, n - 1, 1) {
        Ok(<<0>>) -> trim_trailing_nul_size(bytes, n - 1)
        _ -> n
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

fn parse_header(block: BitArray) -> Result(ParsedHeader, error.ArchiveError) {
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
) -> Result(entry.Entry, error.ArchiveError) {
  use <- bool.guard(
    when: string.byte_size(header.name) > limit.max_entry_name_bytes(limits),
    return: Error(error.ArchiveLimitExceeded(
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
      Error(error.ArchiveInvalid(
        message: "unsupported tar typeflag " <> int.to_string(other),
      ))
  })

  let name_for_depth = trim_trailing_slash(header.name)
  case entry.path_checked(name_for_depth) {
    Ok(parsed_path) ->
      case entry.depth(parsed_path) > limit.max_entry_depth(limits) {
        True ->
          Error(error.ArchiveLimitExceeded(
            limit: "max_entry_depth",
            actual: entry.depth(parsed_path),
          ))
        False -> Ok(Nil)
      }
    Error(_) -> Ok(Nil)
  }
  |> result.try(fn(_) {
    Ok(
      base_entry
      |> entry.with_mode(mode: header.mode)
      |> entry.with_owner(user_id: header.uid, group_id: header.gid)
      |> entry.with_modified_at(unix_seconds: header.mtime),
    )
  })
}

fn regular_entry(
  header: ParsedHeader,
  bytes: BitArray,
) -> Result(entry.Entry, error.ArchiveError) {
  let body = case bit_array.slice(bytes, block_size, header.size) {
    Ok(body) -> body
    Error(_) -> <<>>
  }
  entry.file_checked(path: header.name, body: body)
  |> result.map_error(entry_error_to_archive_error(_, header.name))
}

fn directory_entry(
  header: ParsedHeader,
) -> Result(entry.Entry, error.ArchiveError) {
  entry.directory_checked(path: trim_trailing_slash(header.name))
  |> result.map_error(entry_error_to_archive_error(_, header.name))
}

fn link_entry(
  header: ParsedHeader,
  builder: fn(String, String) -> Result(entry.Entry, entry.EntryError),
) -> Result(entry.Entry, error.ArchiveError) {
  builder(header.name, header.linkname)
  |> result.map_error(entry_error_to_archive_error(_, header.name))
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

fn verify_checksum(block: BitArray) -> Result(Nil, error.ArchiveError) {
  use stored <- result.try(read_checksum_field(block))
  let computed = compute_checksum(block)
  case stored == computed {
    True -> Ok(Nil)
    False ->
      Error(error.ArchiveInvalid(message: "tar header checksum mismatch"))
  }
}

fn read_checksum_field(block: BitArray) -> Result(Int, error.ArchiveError) {
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
  entry_value: entry.Entry,
) -> Result(BitArray, error.ArchiveError) {
  use header <- result.try(build_header(entry_value))
  let body = entry.body(entry_value)
  let body_blocks = pad_to_block(body)
  Ok(bit_array.concat([header, body_blocks]))
}

fn build_header(value: entry.Entry) -> Result(BitArray, error.ArchiveError) {
  let kind = entry.kind(value)
  let path = entry.to_string(entry.path(value))
  let metadata = entry.metadata(value)

  use #(name_field, prefix_field) <- result.try(split_name_field(path, kind))

  let typeflag = case kind {
    entry.File -> 0x30
    entry.Directory -> 0x35
    entry.Symlink -> 0x32
    entry.Hardlink -> 0x31
  }

  let size = case kind {
    entry.File -> bit_array.byte_size(entry.body(value))
    _ -> 0
  }

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
  use mode_field <- result.try(checked_octal_field(
    entry.mode(metadata),
    8,
    "mode",
  ))
  use uid_field <- result.try(checked_octal_field(
    entry.user_id(metadata),
    8,
    "uid",
  ))
  use gid_field <- result.try(checked_octal_field(
    entry.group_id(metadata),
    8,
    "gid",
  ))
  use size_field <- result.try(checked_octal_field(size, 12, "size"))
  use mtime_field <- result.try(checked_octal_field(
    entry.modified_at_unix(metadata),
    12,
    "mtime",
  ))

  let initial =
    bit_array.concat([
      name_field,
      mode_field,
      uid_field,
      gid_field,
      size_field,
      mtime_field,
      checksum_blank_field(),
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

  let checksum_value = compute_checksum(initial)
  let assert Ok(prefix_bits) = bit_array.slice(initial, 0, 148)
  let assert Ok(suffix_bits) =
    bit_array.slice(initial, 156, bit_array.byte_size(initial) - 156)
  Ok(
    bit_array.concat([
      prefix_bits,
      checksum_value_field(checksum_value),
      suffix_bits,
    ]),
  )
}

fn split_name_field(
  path: String,
  kind: entry.EntryKind,
) -> Result(#(BitArray, BitArray), error.ArchiveError) {
  let canonical = case kind {
    entry.Directory -> path <> "/"
    _ -> path
  }

  let canonical_bytes = bit_array.from_string(canonical)
  let size = bit_array.byte_size(canonical_bytes)

  case size <= name_size {
    True ->
      Ok(#(
        right_pad(canonical_bytes, name_size, 0),
        right_pad(<<>>, prefix_size, 0),
      ))
    False -> attempt_prefix_split(canonical, size)
  }
}

fn attempt_prefix_split(
  canonical: String,
  total_bytes: Int,
) -> Result(#(BitArray, BitArray), error.ArchiveError) {
  case total_bytes > name_size + prefix_size + 1 {
    True ->
      Error(error.ArchiveEntryRejected(
        path: canonical,
        reason: "name longer than 256 bytes (USTAR limit)",
      ))
    False -> {
      let segments = string.split(canonical, "/")
      case find_prefix_split(segments) {
        Some(#(prefix, rest)) ->
          Ok(#(
            right_pad(bit_array.from_string(rest), name_size, 0),
            right_pad(bit_array.from_string(prefix), prefix_size, 0),
          ))
        None ->
          Error(error.ArchiveEntryRejected(
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
) -> Result(BitArray, error.ArchiveError) {
  let bytes = bit_array.from_string(value)
  case bit_array.byte_size(bytes) > width {
    True ->
      Error(error.ArchiveEntryRejected(
        path: value,
        reason: kind <> " longer than " <> int.to_string(width) <> " bytes",
      ))
    False -> Ok(right_pad(bytes, width, 0))
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
) -> Result(BitArray, error.ArchiveError) {
  let digit_width = width - 1
  let max_value = pow_int(8, digit_width) - 1
  case value < 0 || value > max_value {
    True ->
      Error(error.ArchiveFieldOverflow(
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
  byte_repeat(0x20, 8)
}

fn checksum_value_field(value: Int) -> BitArray {
  let digits = to_octal_digits(value, 6)
  bit_array.concat([digits, <<0, 0x20>>])
}

fn magic_field() -> BitArray {
  bit_array.from_string("ustar")
  |> right_pad(6, 0)
}

fn version_field() -> BitArray {
  bit_array.from_string("00")
}

fn uname_field() -> BitArray {
  byte_repeat(0, 32)
}

fn gname_field() -> BitArray {
  byte_repeat(0, 32)
}

fn devmajor_field() -> BitArray {
  octal_field(0, 8)
}

fn devminor_field() -> BitArray {
  octal_field(0, 8)
}

fn tail_padding() -> BitArray {
  byte_repeat(0, 12)
}

fn end_marker() -> BitArray {
  byte_repeat(0, block_size * 2)
}

fn pad_to_block(body: BitArray) -> BitArray {
  let size = bit_array.byte_size(body)
  let padded_size = round_up_to_block(size)
  let padding = padded_size - size
  bit_array.concat([body, byte_repeat(0, padding)])
}

fn round_up_to_block(size: Int) -> Int {
  case size % block_size {
    0 -> size
    rem -> size + { block_size - rem }
  }
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
) -> Result(String, error.ArchiveError) {
  case bit_array.slice(block, offset, width) {
    Error(_) ->
      Error(error.ArchiveInvalid(message: "header field out of bounds"))
    Ok(slice) -> {
      let trimmed = strip_trailing_nul(slice)
      case bit_array.to_string(trimmed) {
        Ok(value) -> Ok(value)
        Error(_) ->
          Error(error.ArchiveInvalid(
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
) -> Result(Int, error.ArchiveError) {
  case bit_array.slice(block, offset, width) {
    Error(_) ->
      Error(error.ArchiveInvalid(message: "header field out of bounds"))
    Ok(slice) -> parse_octal(slice, 0, False)
  }
}

fn parse_octal(
  bytes: BitArray,
  acc: Int,
  any_digit: Bool,
) -> Result(Int, error.ArchiveError) {
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
          Error(error.ArchiveInvalid(
            message: "invalid octal byte in tar header",
          ))
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

fn read_byte(block: BitArray, offset: Int) -> Result(Int, error.ArchiveError) {
  case bit_array.slice(block, offset, 1) {
    Ok(<<b>>) -> Ok(b)
    _ -> Error(error.ArchiveInvalid(message: "header byte out of bounds"))
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

fn trim_trailing_slash(value: String) -> String {
  case string.ends_with(value, "/") {
    True -> string.drop_end(value, 1)
    False -> value
  }
}

fn verify_double_zero_terminator(
  bytes: BitArray,
  acc: List(entry.Entry),
) -> Result(List(entry.Entry), error.ArchiveError) {
  case bit_array.slice(bytes, block_size, block_size) {
    Ok(second) ->
      case is_zero_block(second) {
        True -> Ok(acc)
        False ->
          Error(error.ArchiveInvalid(
            message: "tar stream ended after a single zero block",
          ))
      }
    Error(_) ->
      Error(error.ArchiveInvalid(
        message: "tar stream ended after a single zero block",
      ))
  }
}

fn is_zero_block(block: BitArray) -> Bool {
  case block {
    <<>> -> True
    <<0, rest:bytes>> -> is_zero_block(rest)
    _ -> False
  }
}
