import gleam/bit_array
import gleam/list
import gleam/option.{Some}
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
  |> entry.path_of
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
    Error(error.ArchiveLimitExceeded(limit: name, value: _)) ->
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
    Error(error.ArchiveLimitExceeded(limit: "max_members", value: _)) -> Nil
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
