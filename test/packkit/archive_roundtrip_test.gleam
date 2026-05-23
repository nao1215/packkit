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
import packkit/ar
import packkit/archive
import packkit/cpio
import packkit/entry
import packkit/tar
import packkit/zip

fn single_file_roundtrip(
  format_new: fn() -> archive.Archive,
  encode: fn(archive.Archive) -> Result(BitArray, a),
  decode: fn(BitArray) -> Result(archive.Archive, a),
  name: String,
  body: BitArray,
) -> Nil {
  let original =
    format_new()
    |> archive.add(entry: entry.file(path: name, body: body))
  let assert Ok(bytes) = encode(original)
  let assert Ok(decoded) = decode(bytes)
  let assert [restored] = archive.entries(decoded)
  restored |> entry.kind |> should.equal(entry.File)
  restored |> entry.path |> entry.to_string |> should.equal(name)
  restored |> entry.body |> should.equal(body)
}

pub fn tar_roundtrip_single_ascii_test() -> Nil {
  single_file_roundtrip(tar.new, tar.encode, tar.decode, "README.md", <<
    "hello":utf8,
  >>)
}

pub fn tar_roundtrip_single_utf8_test() -> Nil {
  // UTF-8 in filename — USTAR allows arbitrary bytes within the
  // 100-byte name field, so multi-byte UTF-8 should survive.
  single_file_roundtrip(tar.new, tar.encode, tar.decode, "日本語.txt", <<
    "中身":utf8,
  >>)
}

pub fn tar_roundtrip_empty_body_test() -> Nil {
  single_file_roundtrip(tar.new, tar.encode, tar.decode, "empty", <<>>)
}

pub fn zip_roundtrip_single_ascii_test() -> Nil {
  single_file_roundtrip(zip.new, zip.encode, zip.decode, "README.md", <<
    "hello":utf8,
  >>)
}

pub fn zip_roundtrip_empty_body_test() -> Nil {
  single_file_roundtrip(zip.new, zip.encode, zip.decode, "empty", <<>>)
}

pub fn cpio_roundtrip_single_ascii_test() -> Nil {
  single_file_roundtrip(cpio.new, cpio.encode, cpio.decode, "README.md", <<
    "hello":utf8,
  >>)
}

pub fn ar_roundtrip_single_ascii_test() -> Nil {
  // ar names typically fit in 16 bytes; long names use the BSD
  // extension which packkit's `ar.gleam` handles.
  single_file_roundtrip(ar.new, ar.encode, ar.decode, "README.md", <<
    "hello":utf8,
  >>)
}

pub fn ar_roundtrip_long_name_test() -> Nil {
  // 32-byte name triggers the BSD long-name path.
  let name = "a_relatively_long_filename_x.md"
  single_file_roundtrip(ar.new, ar.encode, ar.decode, name, <<"payload">>)
}

pub fn tar_roundtrip_many_entries_test() -> Nil {
  let names = [
    "a.txt", "b.txt", "dir/c.txt", "dir/sub/d.txt", "x", "another/one/here",
  ]
  let original =
    list.fold(names, tar.new(), fn(acc, name) {
      archive.add(acc, entry: entry.file(path: name, body: <<name:utf8>>))
    })
  let assert Ok(bytes) = tar.encode(archive: original)
  let assert Ok(decoded) = tar.decode(bytes: bytes)
  archive.entry_count(decoded) |> should.equal(list.length(names))
  let decoded_names =
    archive.entries(decoded)
    |> list.map(fn(e) { e |> entry.path |> entry.to_string })
  decoded_names |> should.equal(names)
}

pub fn tar_roundtrip_directory_and_symlink_test() -> Nil {
  let original =
    tar.new()
    |> tar.add_file(path: "doc/spec.md", body: <<"spec":utf8>>)
    |> tar.add_symlink(path: "doc/current", target: "spec.md")
  let assert Ok(bytes) = tar.encode(archive: original)
  let assert Ok(decoded) = tar.decode(bytes: bytes)
  let assert [file_e, link_e] = archive.entries(decoded)
  file_e |> entry.kind |> should.equal(entry.File)
  link_e |> entry.kind |> should.equal(entry.Symlink)
  link_e |> entry.link_target |> should.equal(Some("spec.md"))
}

// -- Boundary-value tests on the path validator (`entry.path_checked`) --

pub fn entry_path_empty_rejected_test() -> Nil {
  entry.path_checked("")
  |> should.equal(Error(entry.EmptyPath))
}

pub fn entry_path_just_slash_rejected_test() -> Nil {
  entry.path_checked("/")
  |> should.be_error
  Nil
}

pub fn entry_path_absolute_rejected_test() -> Nil {
  entry.path_checked("/etc/passwd")
  |> should.be_error
  Nil
}

pub fn entry_path_dotdot_segment_rejected_test() -> Nil {
  entry.path_checked("a/../b")
  |> should.be_error
  Nil
}

pub fn entry_path_dot_segment_rejected_test() -> Nil {
  entry.path_checked("a/./b")
  |> should.be_error
  Nil
}

pub fn entry_path_backslash_rejected_test() -> Nil {
  entry.path_checked("a\\b")
  |> should.be_error
  Nil
}

pub fn entry_path_nul_byte_rejected_test() -> Nil {
  entry.path_checked("a\u{0000}b")
  |> should.be_error
  Nil
}

pub fn entry_path_trailing_slash_rejected_test() -> Nil {
  entry.path_checked("a/")
  |> should.be_error
  Nil
}

pub fn entry_path_double_slash_rejected_test() -> Nil {
  entry.path_checked("a//b")
  |> should.be_error
  Nil
}

pub fn entry_path_utf8_allowed_test() -> Nil {
  entry.path_checked("日本語/フォルダ/ファイル.txt")
  |> should.be_ok
  Nil
}

pub fn entry_path_deep_nested_allowed_test() -> Nil {
  entry.path_checked("a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q/r/s/t/u/v/w/x/y/z.txt")
  |> should.be_ok
  Nil
}

pub fn entry_path_with_spaces_allowed_test() -> Nil {
  entry.path_checked("My Documents/Hello World.txt")
  |> should.be_ok
  Nil
}

pub fn entry_file_checked_preserves_path_test() -> Nil {
  let assert Ok(e) = entry.file_checked(path: "a/b/c.txt", body: <<>>)
  e |> entry.path |> entry.to_string |> should.equal("a/b/c.txt")
  e |> entry.body |> should.equal(<<>>)
}

pub fn entry_link_target_for_non_link_is_none_test() -> Nil {
  entry.file(path: "x", body: <<>>)
  |> entry.link_target
  |> should.equal(None)
}
