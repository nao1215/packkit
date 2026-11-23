//// Metamorphic roundtrip tests for the four archive families
//// (tar/zip/cpio/ar): build a logical archive, encode it, decode the
//// result, and assert the entry list matches.  Each family has its
//// own constraints (ar: BSD long-name file model only; cpio: no
//// trailing slash on dir names; tar / zip: full directory + symlink
//// + metadata round-trip), so we test the intersection of what
//// every family supports.

import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import packkit
import packkit/archive
import packkit/fixture
import packkit/internal/entry
import packkit/internal/tar

fn single_file_roundtrip(
  format: archive.ArchiveFormat,
  name: String,
  body: BitArray,
) -> Nil {
  let original =
    fixture.new(format)
    |> fixture.add(entry: fixture.file(path: name, body: body))
  let assert Ok(bytes) = packkit.write(original)
  let assert Ok(decoded) = packkit.read(bytes, format:)
  let assert [restored] = decoded.entries
  restored |> fixture.kind |> should.equal(fixture.File)
  restored.path |> should.equal(name)
  restored |> entry.body |> should.equal(body)
}

pub fn tar_roundtrip_single_ascii_test() -> Nil {
  single_file_roundtrip(archive.Tar, "README.md", <<
    "hello":utf8,
  >>)
}

pub fn tar_roundtrip_single_utf8_test() -> Nil {
  // UTF-8 in filename — USTAR allows arbitrary bytes within the
  // 100-byte name field, so multi-byte UTF-8 should survive.
  single_file_roundtrip(archive.Tar, "日本語.txt", <<
    "中身":utf8,
  >>)
}

pub fn tar_roundtrip_empty_body_test() -> Nil {
  single_file_roundtrip(archive.Tar, "empty", <<>>)
}

pub fn zip_roundtrip_single_ascii_test() -> Nil {
  single_file_roundtrip(archive.Zip, "README.md", <<
    "hello":utf8,
  >>)
}

pub fn zip_roundtrip_empty_body_test() -> Nil {
  single_file_roundtrip(archive.Zip, "empty", <<>>)
}

pub fn cpio_roundtrip_single_ascii_test() -> Nil {
  single_file_roundtrip(archive.Cpio, "README.md", <<
    "hello":utf8,
  >>)
}

pub fn ar_roundtrip_single_ascii_test() -> Nil {
  // ar names typically fit in 16 bytes; long names use the BSD
  // extension which packkit's `ar.gleam` handles.
  single_file_roundtrip(archive.Ar, "README.md", <<
    "hello":utf8,
  >>)
}

pub fn ar_roundtrip_long_name_test() -> Nil {
  // 32-byte name triggers the BSD long-name path.
  let name = "a_relatively_long_filename_x.md"
  single_file_roundtrip(archive.Ar, name, <<"payload">>)
}

pub fn tar_roundtrip_many_entries_test() -> Nil {
  let names = [
    "a.txt", "b.txt", "dir/c.txt", "dir/sub/d.txt", "x", "another/one/here",
  ]
  let original =
    list.fold(names, fixture.new(archive.Tar), fn(acc, name) {
      fixture.add(acc, entry: fixture.file(path: name, body: <<name:utf8>>))
    })
  let assert Ok(bytes) = tar.encode(archive: original)
  let assert Ok(decoded) = packkit.read(bytes, format: archive.Tar)
  list.length(decoded.entries) |> should.equal(list.length(names))
  let decoded_names =
    decoded.entries
    |> list.map(fn(e) { e.path })
  decoded_names |> should.equal(names)
}

pub fn tar_roundtrip_directory_and_symlink_test() -> Nil {
  let original =
    fixture.new(archive.Tar)
    |> fixture.add_file(path: "doc/spec.md", body: <<"spec":utf8>>)
    |> fixture.add_symlink(path: "doc/current", target: "spec.md")
  let assert Ok(bytes) = tar.encode(archive: original)
  let assert Ok(decoded) = packkit.read(bytes, format: archive.Tar)
  let assert [file_e, link_e] = decoded.entries
  file_e |> fixture.kind |> should.equal(fixture.File)
  link_e |> fixture.kind |> should.equal(fixture.Symlink)
  link_e |> entry.link_target |> should.equal(Some("spec.md"))
}

// -- Boundary-value tests on the path validator (`entry.check_path`) --

pub fn entry_path_empty_rejected_test() -> Nil {
  entry.check_path("")
  |> should.equal(Error(entry.EmptyPath))
}

pub fn entry_path_just_slash_rejected_test() -> Nil {
  entry.check_path("/")
  |> should.be_error
  Nil
}

pub fn entry_path_absolute_rejected_test() -> Nil {
  entry.check_path("/etc/passwd")
  |> should.be_error
  Nil
}

pub fn entry_path_dotdot_segment_rejected_test() -> Nil {
  entry.check_path("a/../b")
  |> should.be_error
  Nil
}

pub fn entry_path_dot_segment_rejected_test() -> Nil {
  entry.check_path("a/./b")
  |> should.be_error
  Nil
}

pub fn entry_path_backslash_rejected_test() -> Nil {
  entry.check_path("a\\b")
  |> should.be_error
  Nil
}

pub fn entry_path_nul_byte_rejected_test() -> Nil {
  entry.check_path("a\u{0000}b")
  |> should.be_error
  Nil
}

pub fn entry_path_trailing_slash_rejected_test() -> Nil {
  entry.check_path("a/")
  |> should.be_error
  Nil
}

pub fn entry_path_double_slash_rejected_test() -> Nil {
  entry.check_path("a//b")
  |> should.be_error
  Nil
}

pub fn entry_path_utf8_allowed_test() -> Nil {
  entry.check_path("日本語/フォルダ/ファイル.txt")
  |> should.be_ok
  Nil
}

pub fn entry_path_deep_nested_allowed_test() -> Nil {
  entry.check_path("a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q/r/s/t/u/v/w/x/y/z.txt")
  |> should.be_ok
  Nil
}

pub fn entry_path_with_spaces_allowed_test() -> Nil {
  entry.check_path("My Documents/Hello World.txt")
  |> should.be_ok
  Nil
}

pub fn entry_file_checked_preserves_path_test() -> Nil {
  let assert Ok(e) = entry.file_checked(path: "a/b/c.txt", body: <<>>)
  e.path |> should.equal("a/b/c.txt")
  e |> entry.body |> should.equal(<<>>)
}

pub fn entry_link_target_for_non_link_is_none_test() -> Nil {
  fixture.file(path: "x", body: <<>>)
  |> entry.link_target
  |> should.equal(None)
}
