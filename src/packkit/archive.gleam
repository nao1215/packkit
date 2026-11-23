//// Archives held in memory: a format, a list of entries and an optional
//// comment.
////
//// `Archive` and `Entry` are plain records, so you build them with their
//// constructors and read them by field access or pattern matching. Paths
//// and metadata are checked when the archive is written; see
//// `packkit.write`.

import gleam/int
import gleam/list
import gleam/option.{type Option}
import packkit/codec

/// An archive format.
pub type ArchiveFormat {
  /// POSIX ustar. The reader also accepts GNU long names and PAX headers.
  Tar
  /// ZIP, including Zip64.
  Zip
  /// 7z with one folder.
  SevenZ
  /// cpio in the SVR4 "newc" layout.
  Cpio
  /// Unix ar with BSD long names. The reader also accepts the GNU name
  /// table.
  Ar
}

/// An archive held in memory.
pub type Archive {
  Archive(
    format: ArchiveFormat,
    /// Entries in the order they are written.
    entries: List(Entry),
    /// Archive comment. Only ZIP stores one; the other formats return
    /// `CommentUnsupported` when it is set.
    comment: Option(String),
  )
}

/// One file, directory or link in an archive.
pub type Entry {
  Entry(
    /// Relative path with `/` separators and no trailing slash.
    path: String,
    kind: EntryKind,
    /// Permission bits, such as `0o644`.
    mode: Int,
    user_id: Int,
    group_id: Int,
    /// Modification time in Unix seconds.
    modified_at: Int,
  )
}

/// What an entry holds.
pub type EntryKind {
  File(body: BitArray)
  Directory
  Symlink(target: String)
  Hardlink(target: String)
}

/// Errors from reading and writing archive.
pub type ArchiveError {
  /// The bytes are not a valid archive of the requested format.
  InvalidData(message: String)
  /// The input is valid but uses a feature packkit does not read or write.
  Unsupported(feature: String)
  /// An entry has a path or metadata that cannot be stored safely, such as
  /// an absolute path, `..`, or a negative owner id.
  EntryRejected(path: String, reason: String)
  /// The input went over one of the `Limits`.
  LimitExceeded(limit: String, actual: Int)
  /// A numeric field is too large for the format, such as a tar uid over
  /// 21 bits.
  FieldOverflow(field: String, value: Int, max: Int)
  /// The archive has a comment and the format has no place for one.
  CommentUnsupported(format: ArchiveFormat)
  /// The recipe's format differs from the archive's format.
  FormatMismatch(archive: ArchiveFormat, requested: ArchiveFormat)
  /// A codec in a recipe failed. `step` is `"encode"` or `"decode"`.
  CodecFailed(step: String, cause: codec.CodecError)
}

/// Creates an entry with owner 0, modification time 0 and the usual mode
/// for its kind: `0o644` for files and hard links, `0o755` for
/// directories and `0o777` for symbolic links.
///
/// ## Examples
///
/// ```gleam
/// let entry = new_entry(path: "bin/run", kind: File(<<"#!/bin/sh\n":utf8>>))
/// Entry(..entry, mode: 0o755)
/// ```
///
pub fn new_entry(path path: String, kind kind: EntryKind) -> Entry {
  let mode = case kind {
    File(_) | Hardlink(_) -> 0o644
    Directory -> 0o755
    Symlink(_) -> 0o777
  }
  Entry(path:, kind:, mode:, user_id: 0, group_id: 0, modified_at: 0)
}

/// Returns the first entry whose path is `path`.
///
/// A tar archive can hold two entries with the same path. `tar -x` keeps
/// the last one; to get that entry, search `list.reverse(archive.entries)`
/// instead.
///
/// ## Examples
///
/// ```gleam
/// let archive =
///   Archive(format: Tar, entries: [new_entry("a.txt", File(<<>>))], comment: None)
/// entry_by_path(archive, "a.txt")
/// // -> Ok(Entry(path: "a.txt", ..))
/// entry_by_path(archive, "b.txt")
/// // -> Error(Nil)
/// ```
///
pub fn entry_by_path(
  archive: Archive,
  path path: String,
) -> Result(Entry, Nil) {
  list.find(archive.entries, fn(entry) { entry.path == path })
}

/// Returns the short name of a format: `"tar"`, `"zip"`, `"7z"`,
/// `"cpio"` or `"ar"`.
///
pub fn format_to_string(format: ArchiveFormat) -> String {
  case format {
    Tar -> "tar"
    Zip -> "zip"
    SevenZ -> "7z"
    Cpio -> "cpio"
    Ar -> "ar"
  }
}

/// Describes an error in one line, for logs and command-line output.
///
/// ## Examples
///
/// ```gleam
/// error_to_string(CommentUnsupported(format: Tar))
/// // -> "archive: tar cannot store an archive comment"
/// ```
///
pub fn error_to_string(error: ArchiveError) -> String {
  case error {
    InvalidData(message) -> "archive: invalid data: " <> message
    Unsupported(feature) -> "archive: unsupported: " <> feature
    EntryRejected(path, reason) ->
      "archive: entry \"" <> path <> "\" rejected: " <> reason
    LimitExceeded(limit, actual) ->
      "archive: limit "
      <> limit
      <> " exceeded (actual "
      <> int.to_string(actual)
      <> ")"
    FieldOverflow(field, value, max) ->
      "archive: field "
      <> field
      <> " is "
      <> int.to_string(value)
      <> ", the maximum is "
      <> int.to_string(max)
    CommentUnsupported(format) ->
      "archive: "
      <> format_to_string(format)
      <> " cannot store an archive comment"
    FormatMismatch(archive, requested) ->
      "archive: the archive is "
      <> format_to_string(archive)
      <> " but "
      <> format_to_string(requested)
      <> " was requested"
    CodecFailed(step, cause) ->
      "archive: " <> step <> " failed: " <> codec.error_to_string(cause)
  }
}
