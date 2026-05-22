import gleam/bit_array
import gleam/list
import gleeunit/should
import packkit/archive
import packkit/entry
import packkit/error
import packkit/level
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

pub fn decodes_python_deflate_zip_test() -> Nil {
  // Built with `python3 -m zipfile -c out.zip` style code:
  //   zf.writestr('hello.txt', 'hello world\n' * 50)
  //   zf.writestr('numbers.txt', '0123456789' * 100)
  let bytes = python_deflate_zip()
  let assert Ok(archive_value) = zip.decode(bytes: bytes)
  let entries = archive.entries(archive_value)

  list.map(entries, fn(e) { entry.to_string(entry.path_of(e)) })
  |> should.equal(["hello.txt", "numbers.txt"])

  let assert [hello, numbers] = entries
  entry.body(hello)
  |> should.equal(repeat_bytes(<<"hello world\n":utf8>>, 50))
  entry.body(numbers)
  |> should.equal(repeat_bytes(<<"0123456789":utf8>>, 100))
}

pub fn encode_deflate_method_roundtrip_test() -> Nil {
  let original =
    zip.new()
    |> archive_add_file(
      "greeting.txt",
      repeat_bytes(<<"hello world":utf8>>, 30),
    )

  let assert Ok(bytes) =
    zip.encode_with_method(archive: original, method: zip.deflate(level.best()))
  let assert Ok(decoded) = zip.decode(bytes: bytes)
  let assert [restored] = archive.entries(decoded)
  entry.body(restored)
  |> should.equal(repeat_bytes(<<"hello world":utf8>>, 30))
}

fn repeat_bytes(value: BitArray, times: Int) -> BitArray {
  case times {
    0 -> <<>>
    _ -> bit_array.concat([value, repeat_bytes(value, times - 1)])
  }
}

fn python_deflate_zip() -> BitArray {
  <<
    0x50, 0x4b, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00, 0x08, 0x00, 0x23, 0xad, 0xb6,
    0x5c, 0x17, 0x80, 0xe1, 0x50, 0x15, 0x00, 0x00, 0x00, 0x58, 0x02, 0x00, 0x00,
    0x09, 0x00, 0x00, 0x00, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x2e, 0x74, 0x78, 0x74,
    0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf, 0x2f, 0xca, 0x49, 0xe1, 0xca,
    0x18, 0x65, 0x8f, 0xb2, 0xa9, 0xc4, 0x06, 0x00, 0x50, 0x4b, 0x03, 0x04, 0x14,
    0x00, 0x00, 0x00, 0x08, 0x00, 0x23, 0xad, 0xb6, 0x5c, 0xf1, 0x8f, 0x85, 0x7c,
    0x15, 0x00, 0x00, 0x00, 0xe8, 0x03, 0x00, 0x00, 0x0b, 0x00, 0x00, 0x00, 0x6e,
    0x75, 0x6d, 0x62, 0x65, 0x72, 0x73, 0x2e, 0x74, 0x78, 0x74, 0x33, 0x30, 0x34,
    0x32, 0x36, 0x31, 0x35, 0x33, 0xb7, 0xb0, 0x34, 0x18, 0x65, 0x8d, 0xb2, 0x46,
    0x59, 0xc3, 0x94, 0x05, 0x00, 0x50, 0x4b, 0x01, 0x02, 0x14, 0x03, 0x14, 0x00,
    0x00, 0x00, 0x08, 0x00, 0x23, 0xad, 0xb6, 0x5c, 0x17, 0x80, 0xe1, 0x50, 0x15,
    0x00, 0x00, 0x00, 0x58, 0x02, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x01, 0x00, 0x00, 0x00, 0x00, 0x68,
    0x65, 0x6c, 0x6c, 0x6f, 0x2e, 0x74, 0x78, 0x74, 0x50, 0x4b, 0x01, 0x02, 0x14,
    0x03, 0x14, 0x00, 0x00, 0x00, 0x08, 0x00, 0x23, 0xad, 0xb6, 0x5c, 0xf1, 0x8f,
    0x85, 0x7c, 0x15, 0x00, 0x00, 0x00, 0xe8, 0x03, 0x00, 0x00, 0x0b, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x01, 0x3c, 0x00,
    0x00, 0x00, 0x6e, 0x75, 0x6d, 0x62, 0x65, 0x72, 0x73, 0x2e, 0x74, 0x78, 0x74,
    0x50, 0x4b, 0x05, 0x06, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x02, 0x00, 0x70,
    0x00, 0x00, 0x00, 0x7a, 0x00, 0x00, 0x00, 0x00, 0x00,
  >>
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
