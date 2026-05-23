import gleam/bit_array
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import packkit/archive
import packkit/entry
import packkit/error
import packkit/limit
import packkit/tar

pub fn roundtrip_single_file_test() -> Nil {
  let original =
    tar.new()
    |> tar.add_file(path: "README.md", body: <<"hello":utf8>>)

  let assert Ok(bytes) = tar.encode(archive: original)
  let assert Ok(decoded) = tar.decode(bytes: bytes)

  archive.entry_count(decoded)
  |> should.equal(1)

  let entries = archive.entries(decoded)
  let assert [readme] = entries

  entry.kind(readme)
  |> should.equal("file")

  readme
  |> entry.path
  |> entry.to_string
  |> should.equal("README.md")

  entry.body(readme)
  |> should.equal(<<"hello":utf8>>)
}

pub fn roundtrip_mixed_entries_test() -> Nil {
  let original =
    tar.new()
    |> tar.add_directory(path: "doc")
    |> tar.add_file(path: "doc/spec.md", body: <<"contents":utf8>>)
    |> tar.add_symlink(path: "doc/current", target: "spec.md")

  let assert Ok(bytes) = tar.encode(archive: original)
  let assert Ok(decoded) = tar.decode(bytes: bytes)

  let entries = archive.entries(decoded)

  list.map(entries, entry.kind)
  |> should.equal(["directory", "file", "symlink"])

  let assert [_, file_entry, symlink_entry] = entries

  entry.body(file_entry)
  |> should.equal(<<"contents":utf8>>)

  entry.link_target(symlink_entry)
  |> should.equal(Some("spec.md"))
}

pub fn output_is_block_aligned_test() -> Nil {
  let archive_value =
    tar.new()
    |> tar.add_file(path: "a.txt", body: <<"1234":utf8>>)
    |> tar.add_file(path: "b.txt", body: <<"abcdefghij":utf8>>)

  let assert Ok(bytes) = tar.encode(archive: archive_value)

  bit_array.byte_size(bytes)
  |> should.equal(512 * 6)
}

pub fn empty_archive_is_two_zero_blocks_test() -> Nil {
  let assert Ok(bytes) = tar.encode(archive: tar.new())

  bit_array.byte_size(bytes)
  |> should.equal(1024)

  let assert Ok(decoded) = tar.decode(bytes: bytes)
  archive.entry_count(decoded)
  |> should.equal(0)
}

pub fn input_size_limit_is_enforced_test() -> Nil {
  let assert Ok(bytes) = tar.encode(archive: tar.new())
  let assert Ok(limits) =
    limit.with_max_input_bytes_checked(limit.default(), bytes: 100)

  case tar.decode_with_limits(bytes: bytes, limits: limits) {
    Error(error.ArchiveLimitExceeded(limit: name, actual: _)) ->
      should.equal(name, "max_input_bytes")
    _ -> should.fail()
  }
}

pub fn member_count_limit_is_enforced_test() -> Nil {
  let archive_value =
    tar.new()
    |> tar.add_file(path: "a.txt", body: <<>>)
    |> tar.add_file(path: "b.txt", body: <<>>)
    |> tar.add_file(path: "c.txt", body: <<>>)

  let assert Ok(bytes) = tar.encode(archive: archive_value)
  let assert Ok(limits) =
    limit.with_max_members_checked(limit.default(), count: 2)

  case tar.decode_with_limits(bytes: bytes, limits: limits) {
    Error(error.ArchiveLimitExceeded(limit: "max_members", actual: _)) -> Nil
    _ -> should.fail()
  }
}

// ===== GNU long-name / long-link fixture builders =====
//
// These helpers stitch together hand-crafted USTAR blocks so the test
// can feed packkit a stream that mirrors what GNU tar emits for long
// paths (a `././@LongLink` record with typeflag 'L' or 'K' followed by
// the real entry).  They intentionally duplicate the field layout from
// `src/packkit/tar.gleam` so the test stays independent of internals.

const tar_block_size: Int = 512

fn tar_zero_block() -> BitArray {
  tar_byte_repeat(0, tar_block_size)
}

fn tar_byte_repeat(byte: Int, count: Int) -> BitArray {
  tar_byte_repeat_loop(byte, count, <<>>)
}

fn tar_byte_repeat_loop(byte: Int, count: Int, acc: BitArray) -> BitArray {
  case count {
    0 -> acc
    _ -> tar_byte_repeat_loop(byte, count - 1, <<acc:bits, byte>>)
  }
}

/// Overlay `bytes` into `block` starting at `offset`.  Assumes the
/// region fits inside the 512-byte block.
fn tar_write_at(block: BitArray, offset: Int, bytes: BitArray) -> BitArray {
  let written = bit_array.byte_size(bytes)
  let assert Ok(prefix) = bit_array.slice(block, 0, offset)
  let assert Ok(suffix) =
    bit_array.slice(block, offset + written, tar_block_size - offset - written)
  bit_array.concat([prefix, bytes, suffix])
}

fn tar_octal_digits(value: Int, remaining: Int, acc: BitArray) -> BitArray {
  case remaining {
    0 -> acc
    _ -> {
      let digit = value % 8
      let next = value / 8
      let ch = 0x30 + digit
      tar_octal_digits(next, remaining - 1, <<ch, acc:bits>>)
    }
  }
}

/// `width` covers the digit run plus the trailing NUL terminator.
fn tar_octal_field(value: Int, width: Int) -> BitArray {
  bit_array.concat([tar_octal_digits(value, width - 1, <<>>), <<0>>])
}

fn tar_checksum_loop(block: BitArray, pos: Int, acc: Int) -> Int {
  case block {
    <<>> -> acc
    <<b, rest:bytes>> -> {
      let contribution = case pos >= 148 && pos < 156 {
        True -> 0x20
        False -> b
      }
      tar_checksum_loop(rest, pos + 1, acc + contribution)
    }
    _ -> acc
  }
}

/// USTAR-style checksum: byte sum of the block, treating the 8-byte
/// chksum field at offset 148 as ASCII spaces.
fn tar_checksum(block: BitArray) -> Int {
  tar_checksum_loop(block, 0, 0)
}

/// `"ustar  \\0"` — GNU's variant of the USTAR magic+version field.
fn tar_gnu_magic_version() -> BitArray {
  <<0x75, 0x73, 0x74, 0x61, 0x72, 0x20, 0x20, 0>>
}

/// Build a 512-byte header block with GNU magic.  `linkname` is empty
/// for non-link entries.
fn tar_build_header(
  name name: String,
  size size: Int,
  typeflag typeflag: Int,
  linkname linkname: String,
) -> BitArray {
  let blanked =
    tar_zero_block()
    |> tar_write_at(0, bit_array.from_string(name))
    |> tar_write_at(100, tar_octal_field(0o644, 8))
    |> tar_write_at(108, tar_octal_field(0, 8))
    |> tar_write_at(116, tar_octal_field(0, 8))
    |> tar_write_at(124, tar_octal_field(size, 12))
    |> tar_write_at(136, tar_octal_field(0, 12))
    |> tar_write_at(148, tar_byte_repeat(0x20, 8))
    |> tar_write_at(156, <<typeflag>>)
    |> tar_write_at(157, bit_array.from_string(linkname))
    |> tar_write_at(257, tar_gnu_magic_version())
  let cs = tar_checksum(blanked)
  let chksum_field =
    bit_array.concat([tar_octal_digits(cs, 6, <<>>), <<0, 0x20>>])
  tar_write_at(blanked, 148, chksum_field)
}

/// Pad a body to the next 512-byte boundary with NULs.
fn tar_pad_body(body: BitArray) -> BitArray {
  let n = bit_array.byte_size(body)
  let pad = case n % tar_block_size {
    0 -> 0
    rem -> tar_block_size - rem
  }
  bit_array.concat([body, tar_byte_repeat(0, pad)])
}

// ===== GNU long-name / long-link decode tests =====

pub fn ustar_decodes_100_char_name_test() -> Nil {
  // 100 ASCII bytes exactly fit the USTAR `name` field, so no GNU
  // LongLink record is required.  Regresses the boundary case where
  // packkit should not need any extension support.
  let name = string.repeat("a", times: 100)
  let body = <<"hello100":utf8>>
  let header =
    tar_build_header(name: name, size: 8, typeflag: 0x30, linkname: "")
  let stream =
    bit_array.concat([
      header,
      tar_pad_body(body),
      tar_zero_block(),
      tar_zero_block(),
    ])

  let assert Ok(decoded) = tar.decode(bytes: stream)
  let assert [file_entry] = archive.entries(decoded)
  file_entry
  |> entry.path
  |> entry.to_string
  |> should.equal(name)
  entry.body(file_entry)
  |> should.equal(body)
}

pub fn decodes_gnu_long_name_test() -> Nil {
  // 124 ASCII bytes overflow the 100-byte USTAR `name` field, so GNU
  // tar prefixes the file entry with a `././@LongLink` record
  // (typeflag 'L') whose body carries the real name terminated by a
  // single NUL — the `size` field therefore reports 125 = 124 + NUL.
  // The follow-up entry header keeps the first 100 bytes of the long
  // name in its `name` field; packkit must override that with the
  // LongLink value.
  let long_name = string.repeat("a", times: 124)
  let truncated_name = string.repeat("a", times: 100)
  let body = <<"hello124":utf8>>

  let longlink_body =
    bit_array.concat([bit_array.from_string(long_name), <<0>>])
  let longlink_header =
    tar_build_header(
      name: "././@LongLink",
      size: 125,
      typeflag: 0x4C,
      linkname: "",
    )
  let entry_header =
    tar_build_header(
      name: truncated_name,
      size: 8,
      typeflag: 0x30,
      linkname: "",
    )

  let stream =
    bit_array.concat([
      longlink_header,
      tar_pad_body(longlink_body),
      entry_header,
      tar_pad_body(body),
      tar_zero_block(),
      tar_zero_block(),
    ])

  let assert Ok(decoded) = tar.decode(bytes: stream)
  let assert [file_entry] = archive.entries(decoded)
  file_entry
  |> entry.path
  |> entry.to_string
  |> should.equal(long_name)
  entry.body(file_entry)
  |> should.equal(body)
}

pub fn encoder_rejects_mtime_overflow_test() -> Nil {
  // USTAR mtime is 11 octal digits + NUL, so 2^33-1 is the largest
  // value that fits.  Anything bigger silently dropped its high bits
  // before, corrupting the timestamp on round-trip.
  let assert Ok(base) = entry.file_checked(path: "x.txt", body: <<>>)
  let overflowing =
    base |> entry.with_modified_at(unix_seconds: 8_589_934_592)
  let archive_value =
    archive.new(format: tar.format()) |> archive.add(entry: overflowing)
  case tar.encode(archive: archive_value) {
    Error(error.ArchiveFieldOverflow(field: "tar mtime", value: _, max: _)) ->
      Nil
    _ -> should.fail()
  }
}

pub fn encoder_accepts_boundary_mtime_test() -> Nil {
  // 2^33-1 is exactly representable in the 11-octal-digit field.
  let assert Ok(base) = entry.file_checked(path: "x.txt", body: <<>>)
  let max_mtime =
    base |> entry.with_modified_at(unix_seconds: 8_589_934_591)
  let archive_value =
    archive.new(format: tar.format()) |> archive.add(entry: max_mtime)
  case tar.encode(archive: archive_value) {
    Ok(_) -> Nil
    _ -> should.fail()
  }
}

pub fn encoder_rejects_uid_overflow_test() -> Nil {
  // USTAR uid is 7 octal digits + NUL, so 2^21-1 is the boundary.
  let assert Ok(base) = entry.file_checked(path: "x.txt", body: <<>>)
  let huge =
    base |> entry.with_owner(user_id: 2_097_152, group_id: 0)
  let archive_value =
    archive.new(format: tar.format()) |> archive.add(entry: huge)
  case tar.encode(archive: archive_value) {
    Error(error.ArchiveFieldOverflow(field: "tar uid", value: _, max: _)) -> Nil
    _ -> should.fail()
  }
}

pub fn rejects_single_zero_block_terminator_test() -> Nil {
  // POSIX 1003.1 requires two consecutive zero blocks at end-of-archive.
  // Truncating after only one zero block must be rejected, otherwise we
  // silently accept malformed (or maliciously truncated) streams.
  let archive_value =
    tar.new()
    |> tar.add_file(path: "a.txt", body: <<"data":utf8>>)
  let assert Ok(bytes) = tar.encode(archive: archive_value)
  let total = bit_array.byte_size(bytes)
  // Drop the trailing zero block, leaving exactly one zero block as EOF.
  let assert Ok(truncated) = bit_array.slice(bytes, 0, total - tar_block_size)

  case tar.decode(bytes: truncated) {
    Error(error.ArchiveInvalid(_)) -> Nil
    _ -> should.fail()
  }
}

pub fn rejects_single_zero_block_truncation_via_with_limits_test() -> Nil {
  // `decode_with_limits` must apply the same EOF validation.
  let bytes =
    bit_array.concat([
      tar_build_header(
        name: "x",
        size: 1,
        typeflag: 0x30,
        linkname: "",
      ),
      tar_pad_body(<<"y":utf8>>),
      tar_zero_block(),
    ])

  case tar.decode_with_limits(bytes: bytes, limits: limit.default()) {
    Error(error.ArchiveInvalid(_)) -> Nil
    _ -> should.fail()
  }
}

pub fn round_trips_metadata_test() -> Nil {
  let assert Ok(base) = entry.file_checked(path: "data.bin", body: <<1, 2, 3>>)
  let with_metadata =
    base
    |> entry.with_mode(mode: 0o640)
    |> entry.with_owner(user_id: 1000, group_id: 1000)
    |> entry.with_modified_at(unix_seconds: 1_700_000_000)

  let archive_value =
    archive.new(format: tar.format())
    |> archive.add(entry: with_metadata)

  let assert Ok(bytes) = tar.encode(archive: archive_value)
  let assert Ok(decoded) = tar.decode(bytes: bytes)
  let assert [restored] = archive.entries(decoded)

  let meta = entry.metadata(restored)
  entry.mode(meta)
  |> should.equal(0o640)
  entry.user_id(meta)
  |> should.equal(1000)
  entry.group_id(meta)
  |> should.equal(1000)
  entry.modified_at_unix(meta)
  |> should.equal(1_700_000_000)
}
