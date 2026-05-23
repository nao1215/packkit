import gleam/list
import gleam/option.{type Option, None, Some}
import packkit/entry

/// Opaque archive family marker.
pub opaque type ArchiveFormat {
  ArchiveFormat(name: String)
}

/// Opaque logical archive value independent of any filesystem side
/// effects.
pub opaque type Archive {
  Archive(
    format: ArchiveFormat,
    entries: List(entry.Entry),
    comment: Option(String),
  )
}

/// Tar archive format.
pub fn tar() -> ArchiveFormat {
  ArchiveFormat(name: "tar")
}

/// ZIP archive format.
pub fn zip() -> ArchiveFormat {
  ArchiveFormat(name: "zip")
}

/// 7z archive format.
pub fn seven_z() -> ArchiveFormat {
  ArchiveFormat(name: "7z")
}

/// `cpio` newc archive format.
pub fn cpio_newc() -> ArchiveFormat {
  ArchiveFormat(name: "cpio-newc")
}

/// Unix `ar` archive format.
pub fn ar() -> ArchiveFormat {
  ArchiveFormat(name: "ar")
}

/// Create an empty archive value for the supplied format.
pub fn new(format format: ArchiveFormat) -> Archive {
  Archive(format: format, entries: [], comment: None)
}

/// Create an archive from a full entry list.
pub fn from_entries(
  format format: ArchiveFormat,
  entries entries: List(entry.Entry),
) -> Archive {
  Archive(format: format, entries: entries, comment: None)
}

/// Append an entry to the logical archive.
pub fn add(archive: Archive, entry entry: entry.Entry) -> Archive {
  Archive(..archive, entries: list.append(archive.entries, [entry]))
}

/// Attach an optional archive comment.
pub fn with_comment(archive: Archive, comment comment: String) -> Archive {
  Archive(..archive, comment: Some(comment))
}

/// Read the archive format marker.
pub fn format(archive: Archive) -> ArchiveFormat {
  archive.format
}

/// Read the logical entries.
pub fn entries(archive: Archive) -> List(entry.Entry) {
  archive.entries
}

/// Read the optional archive comment.
pub fn comment(archive: Archive) -> Option(String) {
  archive.comment
}

/// Count the logical entries.
pub fn entry_count(archive: Archive) -> Int {
  list.length(archive.entries)
}

/// Stable string name for an archive format.
pub fn name(format: ArchiveFormat) -> String {
  format.name
}
