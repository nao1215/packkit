import gleam/list
import gleam/option.{type Option, None, Some}
import packkit/entry

/// Stable, pattern-matchable tag identifying an archive family.  The
/// `ArchiveFormat` value is still opaque; this transparent enum is the
/// internal taxonomy used by the facade for compile-time-checked
/// dispatch.  External callers shouldn't need it, but exposing it
/// avoids the previous string-based dispatch.
pub type ArchiveKind {
  Tar
  Zip
  SevenZ
  CpioNewc
  Ar
}

/// Opaque archive family marker.
pub opaque type ArchiveFormat {
  ArchiveFormat(kind: ArchiveKind)
}

/// Opaque logical archive value independent of any filesystem side
/// effects.  `entries` is stored in reverse insertion order so that
/// `add/2` is O(1) instead of O(n); accessors reverse on read.
pub opaque type Archive {
  Archive(
    format: ArchiveFormat,
    reversed_entries: List(entry.Entry),
    comment: Option(String),
  )
}

/// Tar archive format.
pub fn tar() -> ArchiveFormat {
  ArchiveFormat(kind: Tar)
}

/// ZIP archive format.
pub fn zip() -> ArchiveFormat {
  ArchiveFormat(kind: Zip)
}

/// 7z archive format.
pub fn seven_z() -> ArchiveFormat {
  ArchiveFormat(kind: SevenZ)
}

/// `cpio` newc archive format.
pub fn cpio_newc() -> ArchiveFormat {
  ArchiveFormat(kind: CpioNewc)
}

/// Unix `ar` archive format.
pub fn ar() -> ArchiveFormat {
  ArchiveFormat(kind: Ar)
}

/// Create an empty archive value for the supplied format.
pub fn new(format format: ArchiveFormat) -> Archive {
  Archive(format: format, reversed_entries: [], comment: None)
}

/// Create an archive from a full entry list.
pub fn from_entries(
  format format: ArchiveFormat,
  entries entries: List(entry.Entry),
) -> Archive {
  Archive(
    format: format,
    reversed_entries: list.reverse(entries),
    comment: None,
  )
}

/// Append an entry to the logical archive.  Runs in O(1) by prepending
/// to a reversed internal list; observable order is preserved through
/// [entries].
pub fn add(archive: Archive, entry entry: entry.Entry) -> Archive {
  Archive(..archive, reversed_entries: [entry, ..archive.reversed_entries])
}

/// Add a regular file after checked path validation.  Format-agnostic
/// counterpart to `tar.add_file_checked`; works for any archive
/// produced by `new(format:)`.  Format-side restrictions (e.g. `ar`
/// only carries flat files, `7z`'s encoder is not yet implemented)
/// surface at encode time as `ArchiveError`.
pub fn add_file_checked(
  archive archive_value: Archive,
  path path: String,
  body body: BitArray,
) -> Result(Archive, entry.EntryError) {
  case entry.file_checked(path: path, body: body) {
    Ok(value) -> Ok(add(archive_value, entry: value))
    Error(err) -> Error(err)
  }
}

/// Panicking counterpart of `add_file_checked`.
pub fn add_file(
  archive archive_value: Archive,
  path path: String,
  body body: BitArray,
) -> Archive {
  add(archive_value, entry: entry.file(path: path, body: body))
}

/// Add a directory after checked path validation.
pub fn add_directory_checked(
  archive archive_value: Archive,
  path path: String,
) -> Result(Archive, entry.EntryError) {
  case entry.directory_checked(path) {
    Ok(value) -> Ok(add(archive_value, entry: value))
    Error(err) -> Error(err)
  }
}

/// Panicking counterpart of `add_directory_checked`.
pub fn add_directory(
  archive archive_value: Archive,
  path path: String,
) -> Archive {
  add(archive_value, entry: entry.directory(path))
}

/// Add a symbolic link after checked path validation.  Formats whose
/// on-disk layout has no symlink slot (e.g. ZIP without the unix
/// extra field, ar) will reject the archive at encode time; the
/// logical archive value can still carry the entry.
pub fn add_symlink_checked(
  archive archive_value: Archive,
  path path: String,
  target target: String,
) -> Result(Archive, entry.EntryError) {
  case entry.symlink_checked(path: path, target: target) {
    Ok(value) -> Ok(add(archive_value, entry: value))
    Error(err) -> Error(err)
  }
}

/// Panicking counterpart of `add_symlink_checked`.
pub fn add_symlink(
  archive archive_value: Archive,
  path path: String,
  target target: String,
) -> Archive {
  add(archive_value, entry: entry.symlink(path: path, target: target))
}

/// Add a hard link after checked path validation.  Formats without
/// hard-link support reject the archive at encode time.
pub fn add_hardlink_checked(
  archive archive_value: Archive,
  path path: String,
  target target: String,
) -> Result(Archive, entry.EntryError) {
  case entry.hardlink_checked(path: path, target: target) {
    Ok(value) -> Ok(add(archive_value, entry: value))
    Error(err) -> Error(err)
  }
}

/// Panicking counterpart of `add_hardlink_checked`.
pub fn add_hardlink(
  archive archive_value: Archive,
  path path: String,
  target target: String,
) -> Archive {
  add(archive_value, entry: entry.hardlink(path: path, target: target))
}

/// Attach an optional archive comment.
pub fn with_comment(archive: Archive, comment comment: String) -> Archive {
  Archive(..archive, comment: Some(comment))
}

/// Read the archive format marker.
pub fn format(archive: Archive) -> ArchiveFormat {
  archive.format
}

/// Read the logical entries in insertion order.
pub fn entries(archive: Archive) -> List(entry.Entry) {
  list.reverse(archive.reversed_entries)
}

/// Read the optional archive comment.
pub fn comment(archive: Archive) -> Option(String) {
  archive.comment
}

/// Count the logical entries.
pub fn entry_count(archive: Archive) -> Int {
  list.length(archive.reversed_entries)
}

/// Internal tagged kind for the archive format.
pub fn kind(format: ArchiveFormat) -> ArchiveKind {
  format.kind
}

/// Stable string name for an archive format.  Kept for diagnostics
/// and `description` output; internal dispatch uses [kind].
pub fn name(format: ArchiveFormat) -> String {
  case format.kind {
    Tar -> "tar"
    Zip -> "zip"
    SevenZ -> "7z"
    CpioNewc -> "cpio-newc"
    Ar -> "ar"
  }
}
