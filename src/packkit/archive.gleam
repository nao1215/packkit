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
