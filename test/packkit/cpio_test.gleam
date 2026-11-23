import gleam/list
import gleam/option.{Some}
import gleeunit/should
import packkit
import packkit/archive
import packkit/fixture
import packkit/internal/cpio
import packkit/internal/entry

pub fn roundtrip_file_test() -> Nil {
  let original =
    fixture.new(archive.Cpio)
    |> archive_add_file("hello.txt", <<"hello":utf8>>)
    |> archive_add_file("dir/world.txt", <<"world":utf8>>)

  let assert Ok(bytes) = cpio.encode(archive: original)
  let assert Ok(decoded) = packkit.read(bytes, format: archive.Cpio)

  list.map(decoded.entries, fn(e) { #(fixture.kind(e), e.path, entry.body(e)) })
  |> should.equal([
    #(fixture.File, "hello.txt", <<"hello":utf8>>),
    #(fixture.File, "dir/world.txt", <<"world":utf8>>),
  ])
}

pub fn roundtrip_directory_and_symlink_test() -> Nil {
  let assert Ok(dir_entry) = entry.directory_checked(path: "doc")
  let assert Ok(link_entry) =
    entry.symlink_checked(path: "doc/current", target: "spec.md")

  let original =
    fixture.new(archive.Cpio)
    |> fixture.add(entry: dir_entry)
    |> fixture.add(entry: link_entry)

  let assert Ok(bytes) = cpio.encode(archive: original)
  let assert Ok(decoded) = packkit.read(bytes, format: archive.Cpio)
  let assert [restored_dir, restored_link] = decoded.entries

  fixture.kind(restored_dir)
  |> should.equal(fixture.Directory)
  fixture.kind(restored_link)
  |> should.equal(fixture.Symlink)
  entry.link_target(restored_link)
  |> should.equal(Some("spec.md"))
}

pub fn rejects_hardlinks_on_encode_test() -> Nil {
  let assert Ok(link) = entry.hardlink_checked(path: "link", target: "target")
  let archive_value =
    fixture.new(archive.Cpio)
    |> fixture.add(entry: link)

  case cpio.encode(archive: archive_value) {
    Error(archive.EntryRejected(_, _)) -> Nil
    _ -> should.fail()
  }
}

pub fn encoder_rejects_archive_comment_test() -> Nil {
  let with_note =
    fixture.new(archive.Cpio)
    |> archive_add_file("x", <<"x":utf8>>)
    |> fixture.with_comment(comment: "nope")
  case cpio.encode(archive: with_note) {
    Error(archive.CommentUnsupported(format: archive.Cpio)) -> Nil
    _ -> should.fail()
  }
}

pub fn encoder_rejects_uid_overflow_test() -> Nil {
  // newc fields are 8 ASCII hex digits → 0xFFFFFFFF max.  Anything
  // larger silently dropped its high nibbles before this check.
  let assert Ok(base) = entry.file_checked(path: "x.txt", body: <<>>)
  let huge = base |> fixture.with_owner(user_id: 0x1_0000_0000, group_id: 0)
  let archive_value = fixture.new(archive.Cpio) |> fixture.add(entry: huge)
  case cpio.encode(archive: archive_value) {
    Error(archive.FieldOverflow(
      field: "cpio-newc uid",
      value: 0x1_0000_0000,
      max: _,
    )) -> Nil
    _ -> should.fail()
  }
}

pub fn encoder_accepts_uid_boundary_test() -> Nil {
  let assert Ok(base) = entry.file_checked(path: "x.txt", body: <<>>)
  let max_uid = base |> fixture.with_owner(user_id: 0xFFFF_FFFF, group_id: 0)
  let archive_value = fixture.new(archive.Cpio) |> fixture.add(entry: max_uid)
  case cpio.encode(archive: archive_value) {
    Ok(_) -> Nil
    _ -> should.fail()
  }
}

fn archive_add_file(
  archive_value: archive.Archive,
  path: String,
  body: BitArray,
) -> archive.Archive {
  let assert Ok(file_entry) = entry.file_checked(path: path, body: body)
  fixture.add(archive_value, entry: file_entry)
}

pub fn encode_keeps_only_permission_bits_of_mode_test() -> Nil {
  // A mode read from ZIP carries file type bits (0o100644).  The cpio
  // writer takes the type from the entry kind and keeps the
  // permissions, so the archive still reads back.
  let from_zip =
    fixture.with_mode(
      fixture.file(path: "a", body: <<"a":utf8>>),
      mode: 0o100644,
    )
  let assert Ok(bytes) =
    packkit.write(fixture.new(archive.Cpio) |> fixture.add(entry: from_zip))
  let assert Ok(decoded) = packkit.read(bytes, format: archive.Cpio)
  let assert [restored] = decoded.entries
  restored.mode
  |> should.equal(0o644)
}
