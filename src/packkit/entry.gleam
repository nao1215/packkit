import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Validated relative archive path safe to carry as an entry name.
pub opaque type EntryPath {
  EntryPath(raw: String, segments: List(String))
}

/// Common metadata carried by archive entries.
pub opaque type Metadata {
  Metadata(mode: Int, user_id: Int, group_id: Int, modified_at_unix: Int)
}

/// Opaque logical archive entry.
pub opaque type Entry {
  Entry(
    kind: String,
    path: EntryPath,
    body: BitArray,
    link_target: Option(String),
    metadata: Metadata,
  )
}

/// Why a checked entry or path constructor rejected the input.
pub type EntryError {
  EmptyPath
  AbsolutePath(value: String)
  PathTraversal(value: String)
  WindowsPath(value: String)
  EmptySegment(value: String)
  DotSegment(value: String)
  ContainsNul(value: String)
}

/// Validate a relative archive path.
pub fn path_checked(value: String) -> Result(EntryPath, EntryError) {
  use <- bool.guard(when: value == "", return: Error(EmptyPath))
  use <- bool.guard(
    when: string.contains(value, "\u{0000}"),
    return: Error(ContainsNul(value)),
  )
  use <- bool.guard(
    when: string.starts_with(value, "/"),
    return: Error(AbsolutePath(value)),
  )
  use <- bool.guard(
    when: string.contains(value, "\\"),
    return: Error(WindowsPath(value)),
  )

  let segments = string.split(value, "/")

  use <- bool.guard(
    when: contains_empty_segment(segments),
    return: Error(EmptySegment(value)),
  )
  use <- bool.guard(
    when: contains_dot_segment(segments),
    return: Error(DotSegment(value)),
  )
  use <- bool.guard(
    when: contains_traversal_segment(segments),
    return: Error(PathTraversal(value)),
  )

  Ok(EntryPath(raw: value, segments: segments))
}

/// Panicking counterpart of `path_checked`.
pub fn path(value: String) -> EntryPath {
  case path_checked(value) {
    Ok(path) -> path
    Error(_) ->
      panic as "packkit/entry.path: entry path must be a safe relative path"
  }
}

/// Build a regular file entry after path validation.
pub fn file_checked(
  path path: String,
  body body: BitArray,
) -> Result(Entry, EntryError) {
  case path_checked(path) {
    Ok(safe_path) ->
      Ok(Entry(
        kind: "file",
        path: safe_path,
        body: body,
        link_target: None,
        metadata: file_metadata(),
      ))
    Error(error) -> Error(error)
  }
}

/// Panicking counterpart of `file_checked`.
pub fn file(path path: String, body body: BitArray) -> Entry {
  case file_checked(path: path, body: body) {
    Ok(entry) -> entry
    Error(_) ->
      panic as "packkit/entry.file: entry path must be a safe relative path"
  }
}

/// Build a directory entry after path validation.
pub fn directory_checked(path path: String) -> Result(Entry, EntryError) {
  case path_checked(path) {
    Ok(safe_path) ->
      Ok(Entry(
        kind: "directory",
        path: safe_path,
        body: <<>>,
        link_target: None,
        metadata: directory_metadata(),
      ))
    Error(error) -> Error(error)
  }
}

/// Panicking counterpart of `directory_checked`.
pub fn directory(path path: String) -> Entry {
  case directory_checked(path: path) {
    Ok(entry) -> entry
    Error(_) ->
      panic as "packkit/entry.directory: entry path must be a safe relative path"
  }
}

/// Build a symbolic-link entry. The entry path is strictly validated.
/// The link target is preserved as metadata but must not contain NUL.
pub fn symlink_checked(
  path path: String,
  target target: String,
) -> Result(Entry, EntryError) {
  use <- bool.guard(
    when: string.contains(target, "\u{0000}"),
    return: Error(ContainsNul(target)),
  )

  case path_checked(path) {
    Ok(safe_path) ->
      Ok(Entry(
        kind: "symlink",
        path: safe_path,
        body: <<>>,
        link_target: Some(target),
        metadata: link_metadata(),
      ))
    Error(error) -> Error(error)
  }
}

/// Panicking counterpart of `symlink_checked`.
pub fn symlink(path path: String, target target: String) -> Entry {
  case symlink_checked(path: path, target: target) {
    Ok(entry) -> entry
    Error(_) ->
      panic as "packkit/entry.symlink: invalid archive path or link target"
  }
}

/// Build a hard-link entry. The entry path is strictly validated.
/// The link target is preserved as metadata but must not contain NUL.
pub fn hardlink_checked(
  path path: String,
  target target: String,
) -> Result(Entry, EntryError) {
  use <- bool.guard(
    when: string.contains(target, "\u{0000}"),
    return: Error(ContainsNul(target)),
  )

  case path_checked(path) {
    Ok(safe_path) ->
      Ok(Entry(
        kind: "hardlink",
        path: safe_path,
        body: <<>>,
        link_target: Some(target),
        metadata: link_metadata(),
      ))
    Error(error) -> Error(error)
  }
}

/// Panicking counterpart of `hardlink_checked`.
pub fn hardlink(path path: String, target target: String) -> Entry {
  case hardlink_checked(path: path, target: target) {
    Ok(entry) -> entry
    Error(_) ->
      panic as "packkit/entry.hardlink: invalid archive path or link target"
  }
}

/// Read the logical entry kind.
pub fn kind(entry: Entry) -> String {
  entry.kind
}

/// Read the validated entry path.
pub fn path_of(entry: Entry) -> EntryPath {
  entry.path
}

/// Read the raw byte body for file-like entries.
pub fn body(entry: Entry) -> BitArray {
  entry.body
}

/// Read the optional link target.
pub fn link_target(entry: Entry) -> Option(String) {
  entry.link_target
}

/// Read the metadata bundle.
pub fn metadata(entry: Entry) -> Metadata {
  entry.metadata
}

/// Override the entry mode.
pub fn with_mode(entry: Entry, mode mode: Int) -> Entry {
  let Metadata(
    user_id: user_id,
    group_id: group_id,
    modified_at_unix: modified_at_unix,
    ..,
  ) = entry.metadata

  Entry(
    ..entry,
    metadata: Metadata(
      mode: mode,
      user_id: user_id,
      group_id: group_id,
      modified_at_unix: modified_at_unix,
    ),
  )
}

/// Override the entry owner identifiers.
pub fn with_owner(
  entry: Entry,
  user_id user_id: Int,
  group_id group_id: Int,
) -> Entry {
  let Metadata(mode: mode, modified_at_unix: modified_at_unix, ..) =
    entry.metadata

  Entry(
    ..entry,
    metadata: Metadata(
      mode: mode,
      user_id: user_id,
      group_id: group_id,
      modified_at_unix: modified_at_unix,
    ),
  )
}

/// Override the last-modified timestamp.
pub fn with_modified_at(entry: Entry, unix_seconds unix_seconds: Int) -> Entry {
  let Metadata(mode: mode, user_id: user_id, group_id: group_id, ..) =
    entry.metadata

  Entry(
    ..entry,
    metadata: Metadata(
      mode: mode,
      user_id: user_id,
      group_id: group_id,
      modified_at_unix: unix_seconds,
    ),
  )
}

/// Convert an `EntryPath` back to its canonical string form.
pub fn to_string(path: EntryPath) -> String {
  path.raw
}

/// Number of segments in the path.
pub fn depth(path: EntryPath) -> Int {
  list.length(path.segments)
}

/// File mode stored in metadata.
pub fn mode(metadata: Metadata) -> Int {
  metadata.mode
}

/// User identifier stored in metadata.
pub fn user_id(metadata: Metadata) -> Int {
  metadata.user_id
}

/// Group identifier stored in metadata.
pub fn group_id(metadata: Metadata) -> Int {
  metadata.group_id
}

/// Last-modified Unix timestamp stored in metadata.
pub fn modified_at_unix(metadata: Metadata) -> Int {
  metadata.modified_at_unix
}

fn file_metadata() -> Metadata {
  Metadata(mode: 420, user_id: 0, group_id: 0, modified_at_unix: 0)
}

fn directory_metadata() -> Metadata {
  Metadata(mode: 493, user_id: 0, group_id: 0, modified_at_unix: 0)
}

fn link_metadata() -> Metadata {
  Metadata(mode: 511, user_id: 0, group_id: 0, modified_at_unix: 0)
}

fn contains_empty_segment(segments: List(String)) -> Bool {
  case segments {
    [] -> False
    [segment, ..rest] -> segment == "" || contains_empty_segment(rest)
  }
}

fn contains_dot_segment(segments: List(String)) -> Bool {
  case segments {
    [] -> False
    [segment, ..rest] -> segment == "." || contains_dot_segment(rest)
  }
}

fn contains_traversal_segment(segments: List(String)) -> Bool {
  case segments {
    [] -> False
    [segment, ..rest] -> segment == ".." || contains_traversal_segment(rest)
  }
}
