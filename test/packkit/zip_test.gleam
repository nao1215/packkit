import gleam/bit_array
import gleam/list
import gleeunit/should
import packkit/archive
import packkit/entry
import packkit/error
import packkit/zip

pub fn roundtrip_single_file_test() -> Nil {
  let original =
    zip.new()
    |> archive_add_file("hello.txt", <<"hello":utf8>>)

  let assert Ok(bytes) = zip.encode(archive: original)
  let assert Ok(decoded) = zip.decode(bytes: bytes)

  let assert [restored] = archive.entries(decoded)
  entry.to_string(entry.path_of(restored))
  |> should.equal("hello.txt")
  entry.body(restored)
  |> should.equal(<<"hello":utf8>>)
}

pub fn roundtrip_mixed_entries_test() -> Nil {
  let original =
    zip.new()
    |> archive_add_directory("doc")
    |> archive_add_file("doc/spec.md", <<"contents":utf8>>)
    |> archive_add_file("README.md", <<"a":utf8>>)

  let assert Ok(bytes) = zip.encode(archive: original)
  let assert Ok(decoded) = zip.decode(bytes: bytes)
  let entries = archive.entries(decoded)

  list.map(entries, entry.kind)
  |> should.equal(["directory", "file", "file"])

  let assert [_, doc_spec, readme] = entries
  entry.body(doc_spec)
  |> should.equal(<<"contents":utf8>>)
  entry.body(readme)
  |> should.equal(<<"a":utf8>>)
}

pub fn rejects_corrupted_crc_test() -> Nil {
  let original =
    zip.new()
    |> archive_add_file("data.bin", <<1, 2, 3, 4>>)

  let assert Ok(bytes) = zip.encode(archive: original)
  // The 8-byte filename "data.bin" sits between the 30-byte LFH and the
  // 4-byte body, so the body lives at offset 38..42.
  let body_offset = 30 + 8
  let assert Ok(prefix) = bit_array.slice(bytes, 0, body_offset)
  let assert Ok(suffix) =
    bit_array.slice(
      bytes,
      body_offset + 4,
      bit_array.byte_size(bytes) - body_offset - 4,
    )
  let corrupted = bit_array.concat([prefix, <<0, 0, 0, 0>>, suffix])

  case zip.decode(bytes: corrupted) {
    Error(error.ArchiveInvalid(_)) -> Nil
    _ -> should.fail()
  }
}

fn archive_add_file(
  archive_value: archive.Archive,
  path: String,
  body: BitArray,
) -> archive.Archive {
  let assert Ok(file_entry) = entry.file_checked(path: path, body: body)
  archive.add(archive_value, entry: file_entry)
}

fn archive_add_directory(
  archive_value: archive.Archive,
  path: String,
) -> archive.Archive {
  let assert Ok(dir_entry) = entry.directory_checked(path: path)
  archive.add(archive_value, entry: dir_entry)
}
