//// 7z archive scaffolding.
////
//// The 7z format stores entries grouped into folders, each folder
//// described by a coder graph (LZMA2, Delta, BCJ, AES, ...).  The
//// full reader is intentionally deferred while the coder graph and
//// solid-block model are being worked out; this module pins the
//// public API surface.

import packkit/archive as archives
import packkit/error

/// 7z archive format marker.
pub fn format() -> archives.ArchiveFormat {
  archives.seven_z()
}

/// Create an empty 7z archive value.
pub fn new() -> archives.Archive {
  archives.new(format: format())
}

/// Encode a logical archive to a 7z byte stream.  Not yet implemented.
pub fn encode(
  archive _archive_value: archives.Archive,
) -> Result(BitArray, error.ArchiveError) {
  Error(error.ArchiveNotImplemented(feature: "seven_z.encode"))
}

/// Decode a 7z byte stream.  Not yet implemented.
pub fn decode(
  bytes _bytes: BitArray,
) -> Result(archives.Archive, error.ArchiveError) {
  Error(error.ArchiveNotImplemented(feature: "seven_z.decode"))
}
