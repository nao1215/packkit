import gleam/option.{type Option, None, Some}
import packkit/level

/// Pattern-matchable tag identifying the codec family.  `Codec` itself
/// is still opaque; this transparent enum is the internal taxonomy the
/// facade uses for compile-time-checked dispatch.
pub type CodecKind {
  Identity
  Deflate
  Zlib
  Gzip
  Lz4
  Snappy
  Bzip2
  Lzw
  Xz
  Zstd
  Brotli
}

/// Preset dictionary bytes used by codecs that support them.
pub opaque type Dictionary {
  Dictionary(bytes: BitArray)
}

/// Opaque byte-to-byte codec configuration.
pub opaque type Codec {
  Codec(
    kind: CodecKind,
    level: Option(level.Level),
    dictionary: Option(Dictionary),
  )
}

/// No-op codec useful for testing and raw recipe assembly.
pub fn identity() -> Codec {
  Codec(kind: Identity, level: None, dictionary: None)
}

/// Gzip wrapper over deflate.
pub fn gzip() -> Codec {
  Codec(kind: Gzip, level: Some(level.default()), dictionary: None)
}

/// Zlib wrapper over deflate.
pub fn zlib() -> Codec {
  Codec(kind: Zlib, level: Some(level.default()), dictionary: None)
}

/// Raw deflate stream.
pub fn deflate() -> Codec {
  Codec(kind: Deflate, level: Some(level.default()), dictionary: None)
}

/// LZ4 frame format.
pub fn lz4() -> Codec {
  Codec(kind: Lz4, level: None, dictionary: None)
}

/// Snappy framed format.
pub fn snappy() -> Codec {
  Codec(kind: Snappy, level: None, dictionary: None)
}

/// BZip2 stream.  Defaults to level 9 (900 KiB block size) to match
/// the canonical `bzip2` default and the level `bzip2.encode` uses
/// when no level is supplied explicitly.
pub fn bzip2() -> Codec {
  Codec(kind: Bzip2, level: Some(level.custom(9)), dictionary: None)
}

/// XZ stream.
pub fn xz() -> Codec {
  Codec(kind: Xz, level: Some(level.default()), dictionary: None)
}

/// Brotli stream.
pub fn brotli() -> Codec {
  Codec(kind: Brotli, level: Some(level.default()), dictionary: None)
}

/// Zstandard stream.
pub fn zstd() -> Codec {
  Codec(kind: Zstd, level: Some(level.default()), dictionary: None)
}

/// Unix LZW `.Z` stream.
pub fn lzw() -> Codec {
  Codec(kind: Lzw, level: None, dictionary: None)
}

/// Build a dictionary value from raw bytes.
pub fn dictionary(bytes bytes: BitArray) -> Dictionary {
  Dictionary(bytes: bytes)
}

/// Access the raw bytes stored in a dictionary.
pub fn dictionary_bytes(dict: Dictionary) -> BitArray {
  dict.bytes
}

/// Override the codec's compression level.
pub fn with_level(codec: Codec, level level: level.Level) -> Codec {
  Codec(..codec, level: Some(level))
}

/// Remove any explicit level override.
pub fn clear_level(codec: Codec) -> Codec {
  Codec(..codec, level: None)
}

/// Attach a preset dictionary.
pub fn with_dictionary(codec: Codec, dictionary dictionary: Dictionary) -> Codec {
  Codec(..codec, dictionary: Some(dictionary))
}

/// Remove any preset dictionary.
pub fn clear_dictionary(codec: Codec) -> Codec {
  Codec(..codec, dictionary: None)
}

/// Internal tagged kind for the codec family.
pub fn kind(codec: Codec) -> CodecKind {
  codec.kind
}

/// Codec family name.  Kept for diagnostics and `description` output;
/// internal dispatch uses [kind].
pub fn name(codec: Codec) -> String {
  case codec.kind {
    Identity -> "identity"
    Deflate -> "deflate"
    Zlib -> "zlib"
    Gzip -> "gzip"
    Lz4 -> "lz4"
    Snappy -> "snappy"
    Bzip2 -> "bzip2"
    Lzw -> "lzw"
    Xz -> "xz"
    Zstd -> "zstd"
    Brotli -> "brotli"
  }
}

/// Optional level override.
pub fn level(codec: Codec) -> Option(level.Level) {
  codec.level
}

/// Optional dictionary.
pub fn dictionary_of(codec: Codec) -> Option(Dictionary) {
  codec.dictionary
}

/// `True` when a codec carries a preset dictionary.
pub fn has_dictionary(codec: Codec) -> Bool {
  case codec.dictionary {
    Some(_) -> True
    None -> False
  }
}
