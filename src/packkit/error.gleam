//// Shared public error families for the `packkit` facade and the
//// early scaffold modules.

/// Errors returned by byte-to-byte codec APIs.
pub type CodecError {
  CodecUnsupported(name: String)
  CodecInvalidData(message: String)
  CodecLimitExceeded(limit: String, value: Int)
  CodecDictionaryRequired(name: String)
  CodecNotImplemented(feature: String)
}

/// Errors returned by archive read/write APIs.
pub type ArchiveError {
  ArchiveUnsupported(name: String)
  ArchiveInvalid(message: String)
  ArchiveEntryRejected(path: String, reason: String)
  ArchiveLimitExceeded(limit: String, value: Int)
  ArchiveNotImplemented(feature: String)
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
