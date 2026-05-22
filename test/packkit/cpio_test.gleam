import gleam/list
import gleam/option.{Some}
import gleeunit/should
import packkit/archive
import packkit/cpio
import packkit/entry
import packkit/error

pub fn roundtrip_file_test() -> Nil {
  let original =
    cpio.new()
    |> archive_add_file("hello.txt", <<"hello":utf8>>)
    |> archive_add_file("dir/world.txt", <<"world":utf8>>)

  let assert Ok(bytes) = cpio.encode(archive: original)
  let assert Ok(decoded) = cpio.decode(bytes: bytes)

  list.map(archive.entries(decoded), fn(e) {
    #(entry.kind(e), entry.to_string(entry.path_of(e)), entry.body(e))
  })
  |> should.equal([
    #("file", "hello.txt", <<"hello":utf8>>),
    #("file", "dir/world.txt", <<"world":utf8>>),
  ])
}

pub fn roundtrip_directory_and_symlink_test() -> Nil {
  let assert Ok(dir_entry) = entry.directory_checked(path: "doc")
  let assert Ok(link_entry) =
    entry.symlink_checked(path: "doc/current", target: "spec.md")

  let original =
    archive.new(format: cpio.format())
    |> archive.add(entry: dir_entry)
    |> archive.add(entry: link_entry)

  let assert Ok(bytes) = cpio.encode(archive: original)
  let assert Ok(decoded) = cpio.decode(bytes: bytes)
  let assert [restored_dir, restored_link] = archive.entries(decoded)

  entry.kind(restored_dir)
  |> should.equal("directory")
  entry.kind(restored_link)
  |> should.equal("symlink")
  entry.link_target(restored_link)
  |> should.equal(Some("spec.md"))
}

pub fn rejects_hardlinks_on_encode_test() -> Nil {
  let assert Ok(link) = entry.hardlink_checked(path: "link", target: "target")
  let archive_value =
    archive.new(format: cpio.format())
    |> archive.add(entry: link)

  case cpio.encode(archive: archive_value) {
    Error(error.ArchiveEntryRejected(_, _)) -> Nil
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
