//// Shared public error families for the `packkit` facade and the
//// early scaffold modules.

import gleam/int

/// Errors returned by byte-to-byte codec APIs.
pub type CodecError {
  CodecInvalidData(message: String)
  CodecLimitExceeded(limit: String, actual: Int)
  CodecDictionaryRequired(name: String)
  CodecDictionaryMismatch(name: String)
  /// The codec carries an option (level or preset dictionary) that the
  /// selected encoder/decoder cannot honour.  Distinct from
  /// `CodecNotImplemented` so callers can tell "the codec is
  /// fundamentally unfinished" apart from "this combination of
  /// options is not supported by the current implementation".
  CodecOptionUnsupported(option: String, codec_name: String)
  CodecNotImplemented(feature: String)
}

/// Errors returned by archive read/write APIs.
pub type ArchiveError {
  ArchiveUnsupported(name: String)
  ArchiveInvalid(message: String)
  ArchiveEntryRejected(path: String, reason: String)
  ArchiveLimitExceeded(limit: String, actual: Int)
  ArchiveNotImplemented(feature: String)
  /// Surfaces a structured codec failure that occurred during a
  /// recipe-driven pack/unpack step.  Preserves the underlying
  /// `CodecError` so callers can pattern-match on it instead of
  /// parsing a flattened string.  `step` is a short label such as
  /// "encode" or "decode".
  ArchiveCodecFailed(step: String, cause: CodecError)
  /// The format requested for write/pack does not match the format
  /// stored on the supplied archive value.  An `Archive` is an opaque
  /// value bound to one format at construction time; pretending it is
  /// a different format would silently corrupt the output, so the
  /// facade refuses up-front.
  ArchiveFormatMismatch(archive: String, requested: String)
  /// A numeric metadata field (size, count, offset, timestamp, uid/gid,
  /// mode, ...) is too large for the on-disk representation chosen by
  /// the format.  Surfaced instead of silently truncating to the
  /// field's modulus, which would corrupt the archive.
  ArchiveFieldOverflow(field: String, value: Int, max: Int)
  /// The supplied archive carries an optional comment but the
  /// destination format has no slot for it.  Surfaced instead of
  /// silently dropping the comment on encode.
  ArchiveCommentUnsupported(format: String)
}

/// Errors returned by recipe constructors or validators.
pub type RecipeError {
  RecipeArchiveAlreadySet(current: String)
  RecipeEmptyCodecChain
  RecipeUnsupportedComposition(description: String)
  RecipeNotImplemented(feature: String)
}

/// Errors returned by detection helpers.
pub type DetectError {
  DetectUnknownFormat(input: String)
  DetectNotImplemented(feature: String)
}

// -- human-friendly formatters ----------------------------------------

/// Format a `CodecError` as a single user-facing line.  Hides the
/// constructor names and field labels that `string.inspect` would
/// expose, so the output is suitable for CLI error reporting.
pub fn format_codec_error(err: CodecError) -> String {
  case err {
    CodecInvalidData(message) -> "codec: invalid data — " <> message
    CodecLimitExceeded(limit, actual) ->
      "codec: limit \""
      <> limit
      <> "\" exceeded (actual="
      <> int.to_string(actual)
      <> ")"
    CodecDictionaryRequired(name) ->
      "codec: " <> name <> " requires a preset dictionary"
    CodecDictionaryMismatch(name) ->
      "codec: " <> name <> " preset-dictionary id mismatch"
    CodecOptionUnsupported(option, codec_name) ->
      "codec: "
      <> codec_name
      <> " does not support the requested option \""
      <> option
      <> "\""
    CodecNotImplemented(feature) -> "codec: not yet implemented — " <> feature
  }
}

/// Format an `ArchiveError` as a single user-facing line.  Nested
/// `CodecError` (under `ArchiveCodecFailed`) is rendered through
/// `format_codec_error` so the user sees one continuous sentence.
pub fn format_archive_error(err: ArchiveError) -> String {
  case err {
    ArchiveUnsupported(name) -> "archive: unsupported format \"" <> name <> "\""
    ArchiveInvalid(message) -> "archive: invalid — " <> message
    ArchiveEntryRejected(path, reason) ->
      "archive: entry \"" <> path <> "\" rejected — " <> reason
    ArchiveLimitExceeded(limit, actual) ->
      "archive: limit \""
      <> limit
      <> "\" exceeded (actual="
      <> int.to_string(actual)
      <> ")"
    ArchiveNotImplemented(feature) ->
      "archive: not yet implemented — " <> feature
    ArchiveCodecFailed(step, cause) ->
      "archive: " <> step <> " step — " <> format_codec_error(cause)
    ArchiveFormatMismatch(archive, requested) ->
      "archive: format mismatch (archive was built as \""
      <> archive
      <> "\" but \""
      <> requested
      <> "\" was requested)"
    ArchiveFieldOverflow(field, value, max) ->
      "archive: field \""
      <> field
      <> "\" overflow (value="
      <> int.to_string(value)
      <> ", max="
      <> int.to_string(max)
      <> ")"
    ArchiveCommentUnsupported(format) ->
      "archive: format \"" <> format <> "\" does not carry archive comments"
  }
}

/// Format a `DetectError` as a single user-facing line.
pub fn format_detect_error(err: DetectError) -> String {
  case err {
    DetectUnknownFormat(input) ->
      "detect: could not classify input \"" <> input <> "\""
    DetectNotImplemented(feature) -> "detect: not yet implemented — " <> feature
  }
}

/// Format a `RecipeError` as a single user-facing line.
pub fn format_recipe_error(err: RecipeError) -> String {
  case err {
    RecipeArchiveAlreadySet(current) ->
      "recipe: archive layer is already set to \"" <> current <> "\""
    RecipeEmptyCodecChain -> "recipe: codec chain is empty"
    RecipeUnsupportedComposition(description) ->
      "recipe: unsupported composition — " <> description
    RecipeNotImplemented(feature) -> "recipe: not yet implemented — " <> feature
  }
}
