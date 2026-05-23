//// Shared public error families for the `packkit` facade and the
//// early scaffold modules.

/// Errors returned by byte-to-byte codec APIs.
pub type CodecError {
  CodecInvalidData(message: String)
  CodecLimitExceeded(limit: String, actual: Int)
  CodecDictionaryRequired(name: String)
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
