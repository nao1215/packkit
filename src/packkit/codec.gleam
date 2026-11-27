//// Byte-to-byte compression formats and their errors.
////
//// Pass a `Codec` to `packkit.compress` and `packkit.decompress`, or list
//// codecs in a `packkit.Recipe` to compress a whole archive.

import gleam/int

/// A compression format.
pub type Codec {
  /// Leaves the bytes unchanged.
  Identity
  /// Raw DEFLATE (RFC 1951) with no header.
  Deflate
  /// zlib (RFC 1950).
  Zlib
  /// gzip (RFC 1952). Use `packkit/gzip` to read or write the header.
  Gzip
  /// LZ4 frame format.
  Lz4
  /// Snappy framing format.
  Snappy
  Bzip2
  /// Unix `compress` (`.Z`).
  Lzw
  Xz
  /// Zstandard.
  Zstd
  /// Brotli (RFC 7932).
  Brotli
}

/// Errors from compressing and decompressing.
pub type CodecError {
  /// The input was empty. Every format except `Identity` needs at least
  /// a header, so empty input is never a valid stream.
  EmptyInput
  /// The bytes are not a valid stream of the requested format.
  InvalidData(message: String)
  /// The input went over one of the `Limits`.
  LimitExceeded(limit: String, actual: Int)
  /// The zlib stream was made with a preset dictionary, which packkit
  /// does not support.
  DictionaryRequired
  /// The stream is valid but uses a feature packkit does not read.
  Unsupported(feature: String)
}

/// Describes an error in one line, for logs and command-line output.
///
/// ## Examples
///
/// ```gleam
/// error_to_string(LimitExceeded(limit: "max_input_bytes", actual: 70_000_000))
/// // -> "codec: limit max_input_bytes exceeded (actual 70000000)"
/// ```
///
pub fn error_to_string(error: CodecError) -> String {
  case error {
    EmptyInput -> "codec: empty input"
    InvalidData(message) -> "codec: invalid data: " <> message
    LimitExceeded(limit, actual) ->
      "codec: limit "
      <> limit
      <> " exceeded (actual "
      <> int.to_string(actual)
      <> ")"
    DictionaryRequired -> "codec: the stream needs a preset dictionary"
    Unsupported(feature) -> "codec: unsupported: " <> feature
  }
}
