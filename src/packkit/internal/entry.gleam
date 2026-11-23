//// Checks shared by the archive readers and writers: entry paths must be
//// relative and safe to extract, and metadata must not be negative.

import gleam/bit_array
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import packkit/archive.{type Archive, type ArchiveError, type Entry, Entry}
import packkit/limit.{type Limits}

/// Why a path or link target was rejected.
pub type EntryError {
  EmptyPath
  AbsolutePath
  PathTraversal
  WindowsPath
  EmptySegment
  DotSegment
  ContainsNul
}

/// Checks that `path` is relative, uses `/` separators and has no empty,
/// `.` or `..` segment and no NUL byte.
pub fn check_path(path: String) -> Result(Nil, EntryError) {
  use <- bool.guard(when: path == "", return: Error(EmptyPath))
  use <- bool.guard(
    when: string.contains(path, "\u{0000}"),
    return: Error(ContainsNul),
  )
  use <- bool.guard(
    when: string.starts_with(path, "/"),
    return: Error(AbsolutePath),
  )
  use <- bool.guard(
    when: string.contains(path, "\\"),
    return: Error(WindowsPath),
  )
  let segments = string.split(path, "/")
  use <- bool.guard(
    when: list.contains(segments, ""),
    return: Error(EmptySegment),
  )
  use <- bool.guard(
    when: list.contains(segments, "."),
    return: Error(DotSegment),
  )
  use <- bool.guard(
    when: list.contains(segments, ".."),
    return: Error(PathTraversal),
  )
  Ok(Nil)
}

/// Number of `/`-separated segments in a path.
pub fn depth(path: String) -> Int {
  list.length(string.split(path, "/"))
}

/// Builds a file entry with the default metadata after checking the path.
pub fn file_checked(
  path path: String,
  body body: BitArray,
) -> Result(Entry, EntryError) {
  use _ <- result.map(check_path(path))
  archive.new_entry(path:, kind: archive.File(body))
}

/// Builds a directory entry with the default metadata after checking the
/// path.
pub fn directory_checked(path path: String) -> Result(Entry, EntryError) {
  use _ <- result.map(check_path(path))
  archive.new_entry(path:, kind: archive.Directory)
}

/// Builds a symbolic link after checking the path and the target.
pub fn symlink_checked(
  path path: String,
  target target: String,
) -> Result(Entry, EntryError) {
  use _ <- result.try(check_target(target))
  use _ <- result.map(check_path(path))
  archive.new_entry(path:, kind: archive.Symlink(target))
}

/// Builds a hard link after checking the path and the target.
pub fn hardlink_checked(
  path path: String,
  target target: String,
) -> Result(Entry, EntryError) {
  use _ <- result.try(check_target(target))
  use _ <- result.map(check_path(path))
  archive.new_entry(path:, kind: archive.Hardlink(target))
}

fn check_target(target: String) -> Result(Nil, EntryError) {
  use <- bool.guard(
    when: string.contains(target, "\u{0000}"),
    return: Error(ContainsNul),
  )
  Ok(Nil)
}

/// The body of a file entry, or an empty bit array for other kinds.
pub fn body(entry: Entry) -> BitArray {
  case entry.kind {
    archive.File(body) -> body
    archive.Directory | archive.Symlink(_) | archive.Hardlink(_) -> <<>>
  }
}

/// The target of a link entry.
pub fn link_target(entry: Entry) -> Option(String) {
  case entry.kind {
    archive.Symlink(target) | archive.Hardlink(target) -> Some(target)
    archive.File(_) | archive.Directory -> None
  }
}

/// Converts a rejected path into the archive error the readers return.
pub fn to_archive_error(error: EntryError, path: String) -> ArchiveError {
  let reason = case error {
    EmptyPath -> "empty path"
    AbsolutePath -> "absolute path"
    PathTraversal -> "path traversal"
    WindowsPath -> "windows path"
    EmptySegment -> "empty segment"
    DotSegment -> "dot segment"
    ContainsNul -> "nul byte"
  }
  archive.EntryRejected(path:, reason:)
}

/// Checks every entry before it is written: the path must pass
/// `check_path`, a link target must not contain NUL, and the mode, owner
/// ids and modification time must not be negative. Upper bounds depend
/// on the format and are checked by each writer.
pub fn validate_all(entries: List(Entry)) -> Result(Nil, ArchiveError) {
  list.try_each(entries, validate)
}

fn validate(entry: Entry) -> Result(Nil, ArchiveError) {
  let Entry(path:, mode:, user_id:, group_id:, modified_at:, ..) = entry
  use _ <- result.try(
    check_path(path)
    |> result.try(fn(_) {
      case link_target(entry) {
        Some(target) -> check_target(target)
        None -> Ok(Nil)
      }
    })
    |> result.map_error(to_archive_error(_, path)),
  )
  let reject = fn(reason) { Error(archive.EntryRejected(path:, reason:)) }
  case mode < 0, user_id < 0 || group_id < 0, modified_at < 0 {
    True, _, _ -> reject("negative mode")
    _, True, _ -> reject("negative owner id")
    _, _, True -> reject("negative modification time")
    False, False, False -> Ok(Nil)
  }
}

/// Returns `CommentUnsupported` when `archive` has a comment, for formats
/// with no place to store one.
pub fn reject_comment(archive: Archive) -> Result(Nil, ArchiveError) {
  case archive.comment {
    None -> Ok(Nil)
    Some(_) -> Error(archive.CommentUnsupported(format: archive.format))
  }
}

/// Builds the archive a reader returns from its entries in reverse order,
/// after checking that the file bodies together fit in
/// `max_output_bytes`. The tar, cpio and ar readers slice the bodies out
/// of the input, so the check runs once at the end.
pub fn finish(
  reversed: List(Entry),
  format: archive.ArchiveFormat,
  limits: Limits,
) -> Result(Archive, ArchiveError) {
  let total =
    list.fold(reversed, 0, fn(total, entry) {
      total + bit_array.byte_size(body(entry))
    })
  use <- bool.guard(
    when: total > limits.max_output_bytes,
    return: Error(archive.LimitExceeded(
      limit: "max_output_bytes",
      actual: total,
    )),
  )
  Ok(archive.Archive(format:, entries: list.reverse(reversed), comment: None))
}

/// Returns `LimitExceeded` when a reader is about to keep its
/// `count`-th entry and `count` is over `max_members`.
pub fn check_member_limit(
  count: Int,
  limits: Limits,
) -> Result(Nil, ArchiveError) {
  case count > limits.max_members {
    True -> Error(archive.LimitExceeded(limit: "max_members", actual: count))
    False -> Ok(Nil)
  }
}

/// Drops one trailing `/`, which tar and ZIP put after directory names.
pub fn strip_trailing_slash(path: String) -> String {
  case string.ends_with(path, "/") {
    True -> string.drop_end(path, 1)
    False -> path
  }
}

/// Returns `LimitExceeded` when the archive is larger than
/// `max_input_bytes`.
pub fn check_input(
  input: BitArray,
  limits: Limits,
) -> Result(Nil, ArchiveError) {
  let size = bit_array.byte_size(input)
  case size > limits.max_input_bytes {
    True -> Error(archive.LimitExceeded(limit: "max_input_bytes", actual: size))
    False -> Ok(Nil)
  }
}
