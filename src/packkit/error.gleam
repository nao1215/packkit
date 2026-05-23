//// Shared public error families for the `packkit` facade and the
//// early scaffold modules.

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
