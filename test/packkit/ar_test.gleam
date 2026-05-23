import gleam/list
import gleeunit/should
import packkit/ar
import packkit/archive
import packkit/entry
import packkit/error

pub fn roundtrip_file_test() -> Nil {
  let original =
    ar.new()
    |> archive_add_file("a.o", <<1, 2, 3>>)
    |> archive_add_file("b.o", <<4, 5, 6, 7>>)

  let assert Ok(bytes) = ar.encode(archive: original)
  let assert Ok(decoded) = ar.decode(bytes: bytes)

  list.map(archive.entries(decoded), fn(e) {
    #(entry.to_string(entry.path(e)), entry.body(e))
  })
  |> should.equal([#("a.o", <<1, 2, 3>>), #("b.o", <<4, 5, 6, 7>>)])
}

pub fn roundtrip_long_name_test() -> Nil {
  let path = "this-is-a-very-long-object-name-that-overflows-16-bytes.o"
  let body = <<"long-payload":utf8>>

  let original = ar.new() |> archive_add_file(path, body)
  let assert Ok(bytes) = ar.encode(archive: original)
  let assert Ok(decoded) = ar.decode(bytes: bytes)
  let assert [restored] = archive.entries(decoded)

  entry.to_string(entry.path(restored))
  |> should.equal(path)
  entry.body(restored)
  |> should.equal(body)
}

pub fn rejects_directory_entries_test() -> Nil {
  let assert Ok(dir_entry) = entry.directory_checked(path: "build")
  let archive_value =
    archive.new(format: ar.format())
    |> archive.add(entry: dir_entry)

  case ar.encode(archive: archive_value) {
    Error(error.ArchiveEntryRejected(_, _)) -> Nil
    _ -> should.fail()
  }
}

pub fn encoder_rejects_uid_overflow_test() -> Nil {
  // The ar uid field is 6 ASCII decimal digits.  999_999 fits;
  // 1_000_000 does not, and used to silently truncate via
  // `right_pad`.
  let assert Ok(base) = entry.file_checked(path: "a.o", body: <<>>)
  let huge = base |> entry.with_owner(user_id: 1_000_000, group_id: 0)
  let archive_value = archive.new(format: ar.format()) |> archive.add(entry: huge)
  case ar.encode(archive: archive_value) {
    Error(error.ArchiveFieldOverflow(field: "ar uid", value: 1_000_000, max: _)) ->
      Nil
    _ -> should.fail()
  }
}

pub fn encoder_accepts_uid_boundary_test() -> Nil {
  let assert Ok(base) = entry.file_checked(path: "a.o", body: <<>>)
  let max_uid = base |> entry.with_owner(user_id: 999_999, group_id: 0)
  let archive_value =
    archive.new(format: ar.format()) |> archive.add(entry: max_uid)
  case ar.encode(archive: archive_value) {
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
  archive.add(archive_value, entry: file_entry)
}
