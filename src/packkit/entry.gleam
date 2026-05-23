import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Validated relative archive path safe to carry as an entry name.
pub opaque type EntryPath {
  EntryPath(raw: String, segments: List(String))
}

/// Pattern-matchable tag identifying the kind of an `Entry`.  The
/// `Entry` itself stays opaque; this transparent enum replaces the
/// previous stringly-typed kind so callers and encoders get
/// compile-time exhaustiveness instead of "did I spell that right?".
pub type EntryKind {
  File
  Directory
  Symlink
  Hardlink
}

/// Common metadata carried by archive entries.
pub opaque type Metadata {
  Metadata(mode: Int, user_id: Int, group_id: Int, modified_at_unix: Int)
}

/// Opaque logical archive entry.
pub opaque type Entry {
  Entry(
    kind: EntryKind,
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

/// Why a checked metadata setter rejected the input.  Distinct from
/// the path-validation `EntryError` so callers can pattern-match on the
/// numeric-field cases without conflating them.
pub type MetadataError {
  /// `mode` must fit in 16 unsigned bits (the widest field shape any
  /// of our archive families serialise it through).
  ModeOutOfRange(value: Int)
  /// `uid` / `gid` must be non-negative.  Maximum is 2^32-1 (the
  /// widest format-side cap, cpio newc).
  OwnerOutOfRange(value: Int)
  /// `modified_at_unix` must be non-negative.  Maximum is 2^32-1
  /// (32-bit gzip / cpio newc cap); larger timestamps are rejected
  /// here rather than silently corrupted at encode time.
  ModifiedAtOutOfRange(value: Int)
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

/// Panicking counterpart of `path_checked`.  The getter on `Entry`
/// claims the short name; this constructor takes the explicit suffix.
pub fn path_unchecked(value: String) -> EntryPath {
  case path_checked(value) {
    Ok(path) -> path
    Error(_) ->
      panic as "packkit/entry.path_unchecked: entry path must be a safe relative path"
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
        kind: File,
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
        kind: Directory,
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
        kind: Symlink,
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
        kind: Hardlink,
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
pub fn kind(entry: Entry) -> EntryKind {
  entry.kind
}

/// Read the validated entry path.
pub fn path(entry: Entry) -> EntryPath {
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

/// Maximum mode the metadata can carry.  Sized to cover the 16-bit
/// `external_attrs >> 16` window that ZIP and the widest POSIX mode
/// shape both fit into.  Stricter than uid/gid/mtime because no archive
/// family in scope uses a mode wider than 16 bits.
const mode_max: Int = 0xFFFF

/// Override the entry mode.  Out-of-range values panic; use
/// [with_mode_checked] for caller-controlled error handling.
pub fn with_mode(entry: Entry, mode mode: Int) -> Entry {
  case with_mode_checked(entry, mode: mode) {
    Ok(e) -> e
    Error(_) ->
      panic as "packkit/entry.with_mode: mode must be in the inclusive range 0..0xFFFF"
  }
}

/// Override the entry mode after validating it fits the widest mode
/// field any of our archive families serialise it through.
pub fn with_mode_checked(
  entry: Entry,
  mode mode: Int,
) -> Result(Entry, MetadataError) {
  use <- bool.guard(
    when: mode < 0 || mode > mode_max,
    return: Error(ModeOutOfRange(value: mode)),
  )
  let Metadata(
    user_id: user_id,
    group_id: group_id,
    modified_at_unix: modified_at_unix,
    ..,
  ) = entry.metadata

  Ok(
    Entry(
      ..entry,
      metadata: Metadata(
        mode: mode,
        user_id: user_id,
        group_id: group_id,
        modified_at_unix: modified_at_unix,
      ),
    ),
  )
}

/// Override the entry owner identifiers.  Negative values panic;
/// see [with_owner_checked] for the validated variant.  No upper
/// bound is enforced here — format-specific encoders (tar, ar, cpio
/// newc) each apply their own narrower field-width checks at encode
/// time, so a value that's valid for one format and oversized for
/// another can still be expressed as an `Entry`.
pub fn with_owner(
  entry: Entry,
  user_id user_id: Int,
  group_id group_id: Int,
) -> Entry {
  case with_owner_checked(entry, user_id: user_id, group_id: group_id) {
    Ok(e) -> e
    Error(_) ->
      panic as "packkit/entry.with_owner: uid/gid must be non-negative"
  }
}

/// Override the entry owner identifiers after validating they are
/// non-negative.  Format-side overflow (e.g. tar's 21-bit field) is
/// still surfaced at encode time as `ArchiveFieldOverflow`.
pub fn with_owner_checked(
  entry: Entry,
  user_id user_id: Int,
  group_id group_id: Int,
) -> Result(Entry, MetadataError) {
  use <- bool.guard(
    when: user_id < 0,
    return: Error(OwnerOutOfRange(value: user_id)),
  )
  use <- bool.guard(
    when: group_id < 0,
    return: Error(OwnerOutOfRange(value: group_id)),
  )
  let Metadata(mode: mode, modified_at_unix: modified_at_unix, ..) =
    entry.metadata

  Ok(
    Entry(
      ..entry,
      metadata: Metadata(
        mode: mode,
        user_id: user_id,
        group_id: group_id,
        modified_at_unix: modified_at_unix,
      ),
    ),
  )
}

/// Override the last-modified timestamp.  Negative values panic;
/// see [with_modified_at_checked] for the validated variant.  As
/// with [with_owner], the format-specific upper bound (gzip 32-bit,
/// tar 11-octal-digit, …) is enforced at encode time.
pub fn with_modified_at(entry: Entry, unix_seconds unix_seconds: Int) -> Entry {
  case with_modified_at_checked(entry, unix_seconds: unix_seconds) {
    Ok(e) -> e
    Error(_) ->
      panic as "packkit/entry.with_modified_at: unix_seconds must be non-negative"
  }
}

/// Override the last-modified timestamp after validating it is
/// non-negative.  The format-specific upper bound is enforced at
/// encode time as `ArchiveFieldOverflow`.
pub fn with_modified_at_checked(
  entry: Entry,
  unix_seconds unix_seconds: Int,
) -> Result(Entry, MetadataError) {
  use <- bool.guard(
    when: unix_seconds < 0,
    return: Error(ModifiedAtOutOfRange(value: unix_seconds)),
  )
  let Metadata(mode: mode, user_id: user_id, group_id: group_id, ..) =
    entry.metadata

  Ok(
    Entry(
      ..entry,
      metadata: Metadata(
        mode: mode,
        user_id: user_id,
        group_id: group_id,
        modified_at_unix: unix_seconds,
      ),
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
