import gleam/option.{None}
import gleeunit/should
import packkit
import packkit/archive.{Archive, Entry}
import packkit/fixture
import packkit/internal/entry

pub fn check_path_accepts_nested_relative_path_test() -> Nil {
  entry.check_path("doc/reference/spec.md")
  |> should.equal(Ok(Nil))
  entry.depth("doc/reference/spec.md")
  |> should.equal(3)
}

pub fn check_path_rejects_unsafe_paths_test() -> Nil {
  entry.check_path("") |> should.equal(Error(entry.EmptyPath))
  entry.check_path("/etc/passwd") |> should.equal(Error(entry.AbsolutePath))
  entry.check_path("a/../b") |> should.equal(Error(entry.PathTraversal))
  entry.check_path("a\\b") |> should.equal(Error(entry.WindowsPath))
  entry.check_path("a//b") |> should.equal(Error(entry.EmptySegment))
  entry.check_path("a/./b") |> should.equal(Error(entry.DotSegment))
  entry.check_path("a\u{0000}b") |> should.equal(Error(entry.ContainsNul))
}

pub fn link_target_must_not_contain_nul_test() -> Nil {
  entry.symlink_checked(path: "s", target: "t\u{0000}")
  |> should.equal(Error(entry.ContainsNul))
  entry.hardlink_checked(path: "h", target: "t\u{0000}")
  |> should.equal(Error(entry.ContainsNul))
}

pub fn new_entry_picks_mode_by_kind_test() -> Nil {
  archive.new_entry(path: "f", kind: archive.File(<<>>)).mode
  |> should.equal(0o644)
  archive.new_entry(path: "d", kind: archive.Directory).mode
  |> should.equal(0o755)
  archive.new_entry(path: "s", kind: archive.Symlink("t")).mode
  |> should.equal(0o777)
  archive.new_entry(path: "h", kind: archive.Hardlink("t")).mode
  |> should.equal(0o644)
}

pub fn write_keeps_large_owner_ids_for_the_format_to_check_test() -> Nil {
  // Upper bounds depend on the format: cpio stores 32-bit owner ids, so
  // a uid that tar could not hold still writes.
  let big_owner =
    Entry(..fixture.file(path: "a.txt", body: <<>>), user_id: 1_000_000)
  let assert Ok(bytes) =
    packkit.write(Archive(
      format: archive.Cpio,
      entries: [big_owner],
      comment: None,
    ))
  let assert Ok(decoded) = packkit.read(bytes, format: archive.Cpio)
  decoded.entries
  |> should.equal([big_owner])
}

pub fn write_rejects_nul_in_link_target_test() -> Nil {
  fixture.new(archive.Tar)
  |> fixture.add_symlink(path: "s", target: "t\u{0000}")
  |> packkit.write
  |> should.equal(Error(archive.EntryRejected(path: "s", reason: "nul byte")))
}
