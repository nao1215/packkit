import gleam/option.{type Option, None, Some}
import packkit/level

/// Preset dictionary bytes used by codecs that support them.
pub opaque type Dictionary {
  Dictionary(bytes: BitArray)
}

/// Opaque byte-to-byte codec configuration.
pub opaque type Codec {
  Codec(
    name: String,
    level: Option(level.Level),
    dictionary: Option(Dictionary),
  )
}

/// No-op codec useful for testing and raw recipe assembly.
pub fn identity() -> Codec {
  Codec(name: "identity", level: None, dictionary: None)
}

/// Gzip wrapper over deflate.
pub fn gzip() -> Codec {
  Codec(name: "gzip", level: Some(level.default()), dictionary: None)
}

/// Zlib wrapper over deflate.
pub fn zlib() -> Codec {
  Codec(name: "zlib", level: Some(level.default()), dictionary: None)
}

/// Raw deflate stream.
pub fn deflate() -> Codec {
  Codec(name: "deflate", level: Some(level.default()), dictionary: None)
}

/// LZ4 frame format.
pub fn lz4_frame() -> Codec {
  Codec(name: "lz4-frame", level: None, dictionary: None)
}

/// Snappy framed format.
pub fn snappy_frame() -> Codec {
  Codec(name: "snappy-frame", level: None, dictionary: None)
}

/// BZip2 stream.
pub fn bzip2() -> Codec {
  Codec(name: "bzip2", level: Some(level.default()), dictionary: None)
}

/// XZ stream.
pub fn xz() -> Codec {
  Codec(name: "xz", level: Some(level.default()), dictionary: None)
}

/// Brotli stream.
pub fn brotli() -> Codec {
  Codec(name: "brotli", level: Some(level.default()), dictionary: None)
}

/// Zstandard stream.
pub fn zstd() -> Codec {
  Codec(name: "zstd", level: Some(level.default()), dictionary: None)
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

/// Codec family name.
pub fn name(codec: Codec) -> String {
  codec.name
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
