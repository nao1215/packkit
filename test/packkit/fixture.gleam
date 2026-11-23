//// Small builders that keep the archive tests short.

import gleam/list
import gleam/option.{None, Some}
import packkit/archive.{type Archive, type Entry, Archive, Entry}

pub type Kind {
  File
  Directory
  Symlink
  Hardlink
}

pub fn kind(entry: Entry) -> Kind {
  case entry.kind {
    archive.File(_) -> File
    archive.Directory -> Directory
    archive.Symlink(_) -> Symlink
    archive.Hardlink(_) -> Hardlink
  }
}

pub fn new(format: archive.ArchiveFormat) -> Archive {
  Archive(format:, entries: [], comment: None)
}

pub fn add(archive: Archive, entry entry: Entry) -> Archive {
  Archive(..archive, entries: list.append(archive.entries, [entry]))
}

pub fn with_comment(archive: Archive, comment comment: String) -> Archive {
  Archive(..archive, comment: Some(comment))
}

pub fn file(path path: String, body body: BitArray) -> Entry {
  archive.new_entry(path:, kind: archive.File(body))
}

pub fn directory(path path: String) -> Entry {
  archive.new_entry(path:, kind: archive.Directory)
}

pub fn symlink(path path: String, target target: String) -> Entry {
  archive.new_entry(path:, kind: archive.Symlink(target))
}

pub fn hardlink(path path: String, target target: String) -> Entry {
  archive.new_entry(path:, kind: archive.Hardlink(target))
}

pub fn add_file(
  archive: Archive,
  path path: String,
  body body: BitArray,
) -> Archive {
  add(archive, entry: file(path:, body:))
}

pub fn add_directory(archive: Archive, path path: String) -> Archive {
  add(archive, entry: directory(path:))
}

pub fn add_symlink(
  archive: Archive,
  path path: String,
  target target: String,
) -> Archive {
  add(archive, entry: symlink(path:, target:))
}

pub fn add_hardlink(
  archive: Archive,
  path path: String,
  target target: String,
) -> Archive {
  add(archive, entry: hardlink(path:, target:))
}

pub fn with_mode(entry: Entry, mode mode: Int) -> Entry {
  Entry(..entry, mode:)
}

pub fn with_owner(
  entry: Entry,
  user_id user_id: Int,
  group_id group_id: Int,
) -> Entry {
  Entry(..entry, user_id:, group_id:)
}

pub fn with_modified_at(entry: Entry, unix_seconds modified_at: Int) -> Entry {
  Entry(..entry, modified_at:)
}
