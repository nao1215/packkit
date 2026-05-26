//// ZIP archive encoder and decoder.
////
//// This module implements the PKZIP local-file-header / central
//// directory layout for the "stored" (uncompressed) and "deflate"
//// methods, plus the Zip64 extensions (APPNOTE.TXT §4.4) needed to
//// carry archives with > 65535 entries, central-directory regions
//// > 4 GiB, individual entries > 4 GiB, or local-header offsets
//// > 4 GiB.  ZIP is modelled as an archive family, not a recipe:
//// per-entry compression is selected through `Method` values rather
//// than through `packkit/recipe`.
////
//// On the decoder side: when the standard EOCD record has any
//// sentinel field (`0xFFFF` for the 16-bit slots, `0xFFFFFFFF` for
//// the 32-bit slots), the decoder follows the Zip64 EOCD locator at
//// `eocd_offset - 20` to the Zip64 EOCD record and reads the real
//// 64-bit values from there.  Per-entry Zip64 extra fields
//// (`header_id = 0x0001`) are parsed in both the central-directory
//// entry and the local file header so that compressed / uncompressed
//// sizes and local-header offsets above the 4 GiB boundary decode
//// correctly.
////
//// On the encoder side: each entry transparently switches to the
//// Zip64 extra field when any of its `uncompressed_size`,
//// `compressed_size`, or `local_header_offset` would not fit in 32
//// bits.  Archives whose total entry count or central-directory
//// region overflow the legacy 16-/32-bit EOCD slots also emit a
//// Zip64 EOCD record + locator so the resulting bytes round-trip
//// through any conforming Zip64 reader.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import packkit/archive as archives
import packkit/bzip2
import packkit/checksum
import packkit/codec as codecs
import packkit/deflate
import packkit/entry
import packkit/error
import packkit/internal/lzma
import packkit/level
import packkit/limit
import packkit/xz
import packkit/zstd

const local_file_signature: Int = 0x04034b50

const central_directory_signature: Int = 0x02014b50

const eocd_signature: Int = 0x06054b50

const zip64_eocd_locator_signature: Int = 0x07064b50

const zip64_eocd_signature: Int = 0x06064b50

const zip64_extra_id: Int = 0x0001

// InfoZIP "Extended Timestamp" extra field (header_id 'UT' = 0x5455).
// Carries up to three Unix-epoch timestamps (mtime, atime, ctime) at
// second resolution, supplementing the 2-second-resolution DOS fields
// in the local + central headers.  packkit only emits the mtime slot
// since archive entries do not yet track access / creation time, but
// the decoder honours whatever flags the field advertises.
const unix_ts_extra_id: Int = 0x5455

const unix_ts_flag_mtime: Int = 0x01

const method_store: Int = 0

const method_deflate: Int = 8

const method_bzip2: Int = 12

// ZIP method 14 is the PKWARE LZMA wrapper around a raw LZMA1
// stream (NOT the same as standalone `.lzma` or `.xz`).  The wrapper
// adds a 4-byte preamble (SDK version + properties length) before
// the 5-byte LZMA1 property block and the range-coded payload.
const method_lzma: Int = 14

const method_zstd: Int = 93

const method_xz: Int = 95

fn is_supported_method(method: Int) -> Bool {
  method == method_store
  || method == method_deflate
  || method == method_bzip2
  || method == method_lzma
  || method == method_zstd
  || method == method_xz
}

/// `version_needed` value emitted in any entry that carries a Zip64
/// extra field.  PKZIP requires v4.5 (encoded as `45`) for Zip64.
const version_needed_zip64: Int = 45

const version_made_by_unix: Int = 0x0314

const version_needed_store: Int = 10

const version_needed_deflate: Int = 20

const version_needed_bzip2: Int = 46

const version_needed_lzma_family: Int = 63

const external_attr_dir: Int = 0x4000_0000

// DOS date/time sentinel returned by `unix_to_dos_pair` when the
// entry has no recorded mtime or the mtime predates the DOS epoch
// (year 1980).  0x0021 in both fields decodes as 1980-01-01 00:01:02
// — the historic PKZIP convention and what packkit has emitted from
// day one for "no mtime".  The decoder short-circuits this exact pair
// back to `modified_at_unix = 0` so a round-trip with no mtime stays
// at zero rather than rehydrating as an artificial 1980 timestamp.
const default_mtime_dos: Int = 0x0021

const default_mdate_dos: Int = 0x0021

// 315_532_800 = Unix seconds of 1980-01-01 00:00:00 UTC, i.e. the
// DOS-date epoch.  Earlier mtimes do not fit DOS date/time (year - 1980
// would underflow the 7-bit year field) and are clamped to this
// sentinel in the DOS slots; the InfoZIP Extended Timestamp extra
// field still carries the original value for full-fidelity round-trips.
const dos_epoch_unix: Int = 315_532_800

// 4_354_819_200 = Unix seconds of 2108-01-01 00:00:00 UTC, one second
// past the DOS-date ceiling (year 2107 = 1980 + 127 inclusive).  An
// mtime at or beyond this is clamped to the DOS-epoch sentinel; the
// Extended Timestamp extra carries the real value (its int32 LE field
// still fits any second in [-2^31, 2^31 - 1] which covers 1901..2038
// in signed interpretation and 1970..2106 in unsigned, both narrower
// than the clamp window — so future cleanup may relax this).
const dos_epoch_ceiling_unix: Int = 4_354_819_200

/// ZIP-specific entry method marker. This stays distinct from the
/// top-level recipe model because ZIP is an archive family, not a
/// recipe.
pub opaque type Method {
  Method(name: String, inner_codec: Option(codecs.Codec))
}

/// ZIP archive format marker.
pub fn format() -> archives.ArchiveFormat {
  archives.zip()
}

/// Create an empty logical ZIP archive value.
pub fn new() -> archives.Archive {
  archives.new(format: format())
}

/// Stored (uncompressed) ZIP member method.
pub fn store() -> Method {
  Method(name: "store", inner_codec: None)
}

/// Deflate-compressed ZIP member method.
pub fn deflate(level level: level.Level) -> Method {
  Method(
    name: "deflate",
    inner_codec: Some(codecs.deflate() |> codecs.with_level(level: level)),
  )
}

/// Bzip2-compressed ZIP member method (PKZIP method 12).
pub fn bzip2() -> Method {
  Method(name: "bzip2", inner_codec: Some(codecs.bzip2()))
}

/// Zstd-compressed ZIP member method (PKZIP method 93).
pub fn zstd() -> Method {
  Method(name: "zstd", inner_codec: Some(codecs.zstd()))
}

/// xz-compressed ZIP member method (PKZIP method 95).
pub fn xz() -> Method {
  Method(name: "xz", inner_codec: Some(codecs.xz()))
}

/// PKWARE LZMA ZIP member method (PKZIP method 14).  Wraps a raw
/// LZMA1 range-coded stream in the 4-byte SDK preamble + 5-byte
/// property block (`lc=3 / lp=0 / pb=2`, dict size 64 KiB).  The
/// encoder emits the stream with general-purpose flag bit 1 set so
/// the decoder relies on the central-directory uncompressed size
/// instead of an in-stream EOS marker.
pub fn lzma() -> Method {
  // No public packkit codec for LZMA1 yet — keep inner_codec as None
  // so the accessor stays accurate.
  Method(name: "lzma", inner_codec: None)
}

/// Stable method name.
pub fn name(method: Method) -> String {
  method.name
}

/// Optional inner codec corresponding to the method.
pub fn inner_codec(method: Method) -> Option(codecs.Codec) {
  method.inner_codec
}

/// Encode a logical archive into a ZIP byte stream using the stored
/// (uncompressed) method for every entry.
pub fn encode(
  archive archive_value: archives.Archive,
) -> Result(BitArray, error.ArchiveError) {
  encode_with_method(archive: archive_value, method: store())
}

/// Encode a logical archive into a ZIP byte stream using a chosen
/// per-entry method.  Supports `store`, `deflate`, `bzip2`, `zstd`,
/// and `xz`.
pub fn encode_with_method(
  archive archive_value: archives.Archive,
  method method: Method,
) -> Result(BitArray, error.ArchiveError) {
  let entries = archives.entries(archive_value)
  use #(local_blocks, central_blocks) <- result.try(encode_entries(
    entries,
    0,
    [],
    [],
    method,
  ))

  let local_bytes = bit_array.concat(local_blocks)
  let central_bytes = bit_array.concat(central_blocks)
  let central_offset = bit_array.byte_size(local_bytes)
  let central_size = bit_array.byte_size(central_bytes)
  let count = list.length(entries)

  let comment_bytes = case archives.comment(archive_value) {
    Some(c) -> bit_array.from_string(c)
    None -> <<>>
  }
  let comment_size = bit_array.byte_size(comment_bytes)
  use _ <- result.try(check_u16(comment_size, "archive_comment_length"))

  // Decide whether the EOCD record needs Zip64 extensions.  Any of:
  //  * total entry count > 65535
  //  * central directory size > 4 GiB
  //  * central directory offset > 4 GiB
  // forces us to emit a Zip64 EOCD record + locator and put the
  // sentinel 0xFFFF / 0xFFFFFFFF in the legacy EOCD slots so older
  // readers correctly fall through to the Zip64 record.
  let needs_zip64_eocd =
    count > u16_max || central_size > u32_max || central_offset > u32_max

  let zip64_trailer = case needs_zip64_eocd {
    False -> <<>>
    True -> build_zip64_eocd_and_locator(count, central_size, central_offset)
  }

  let eocd_total_entries = case count > u16_max {
    True -> u16_max
    False -> count
  }
  let eocd_central_size = case central_size > u32_max {
    True -> u32_max
    False -> central_size
  }
  let eocd_central_offset = case central_offset > u32_max {
    True -> u32_max
    False -> central_offset
  }

  let eocd =
    bit_array.concat([
      le32(eocd_signature),
      le16(0),
      le16(0),
      le16(eocd_total_entries),
      le16(eocd_total_entries),
      le32(eocd_central_size),
      le32(eocd_central_offset),
      le16(comment_size),
      comment_bytes,
    ])

  Ok(bit_array.concat([local_bytes, central_bytes, zip64_trailer, eocd]))
}

/// Build the Zip64 EOCD record (56 bytes) followed by the Zip64 EOCD
/// locator (20 bytes).  The locator's "Zip64 EOCD record offset" is
/// the byte position of the Zip64 EOCD record relative to the start
/// of the file — i.e. `local_bytes_size + central_bytes_size` since
/// we always write the Zip64 record immediately after the central
/// directory and immediately before the regular EOCD.
fn build_zip64_eocd_and_locator(
  count: Int,
  central_size: Int,
  central_offset: Int,
) -> BitArray {
  // The Zip64 EOCD record is laid out as:
  //   +0  4-byte signature (0x06064b50)
  //   +4  8-byte size of record excluding the first 12 bytes (= 44)
  //   +12 2-byte version made by
  //   +14 2-byte version needed to extract
  //   +16 4-byte disk number (= 0)
  //   +20 4-byte central-directory start disk (= 0)
  //   +24 8-byte entries on this disk
  //   +32 8-byte total entries
  //   +40 8-byte central-directory size
  //   +48 8-byte central-directory offset
  let zip64_eocd =
    bit_array.concat([
      le32(zip64_eocd_signature),
      le64(44),
      le16(version_made_by_unix),
      le16(version_needed_zip64),
      le32(0),
      le32(0),
      le64(count),
      le64(count),
      le64(central_size),
      le64(central_offset),
    ])
  // The locator must record the absolute offset of the Zip64 EOCD
  // record (i.e. file start → record start).  The Zip64 record sits
  // immediately after the central directory, so that offset equals
  // `central_offset + central_size`.
  let zip64_offset = central_offset + central_size
  let zip64_locator =
    bit_array.concat([
      le32(zip64_eocd_locator_signature),
      le32(0),
      le64(zip64_offset),
      le32(1),
    ])
  bit_array.concat([zip64_eocd, zip64_locator])
}

/// Run the deflate encoder honoring the requested level on the inner
/// codec attached to the method.  Level 0 → stored deflate blocks;
/// the implicit default level → fixed-Huffman LZ77; any other level
/// is rejected with a typed `CodecOptionUnsupported`.  Previously this
/// step silently fell back to the default encoder regardless of the
/// caller's level request.
fn deflate_with_level(
  bytes: BitArray,
  inner: Option(codecs.Codec),
) -> Result(BitArray, error.CodecError) {
  let level_value = case inner {
    None -> None
    Some(c) ->
      case codecs.level(c) {
        Some(l) -> Some(level.value(l))
        None -> None
      }
  }
  case level_value {
    None -> deflate.encode(bytes: bytes)
    Some(0) -> deflate.encode_stored_only(bytes: bytes)
    Some(n) ->
      case n == level.value(level.default()) {
        True -> deflate.encode(bytes: bytes)
        False ->
          Error(error.CodecOptionUnsupported(
            option: "level",
            codec_name: "zip-deflate",
          ))
      }
  }
}

const u16_max: Int = 0xFFFF

const u32_max: Int = 0xFFFFFFFF

fn check_u16(value: Int, field: String) -> Result(Nil, error.ArchiveError) {
  case value < 0 || value > u16_max {
    True ->
      Error(error.ArchiveFieldOverflow(
        field: "zip " <> field,
        value: value,
        max: u16_max,
      ))
    False -> Ok(Nil)
  }
}

fn check_u32(value: Int, field: String) -> Result(Nil, error.ArchiveError) {
  case value < 0 || value > u32_max {
    True ->
      Error(error.ArchiveFieldOverflow(
        field: "zip " <> field,
        value: value,
        max: u32_max,
      ))
    False -> Ok(Nil)
  }
}

/// Decode a ZIP archive using default limits.
pub fn decode(
  bytes bytes: BitArray,
) -> Result(archives.Archive, error.ArchiveError) {
  decode_internal(bytes, None, limit.default())
}

/// Decode a ZIP archive using explicit limits.
pub fn decode_with_limits(
  bytes bytes: BitArray,
  limits limits: limit.Limits,
) -> Result(archives.Archive, error.ArchiveError) {
  decode_internal(bytes, None, limits)
}

/// Decode a ZIP archive whose entries may be protected by the
/// PKWARE traditional ("ZipCrypto") encryption scheme.  The
/// password is applied to every encrypted entry; entries without
/// the gp-flag encryption bit decode unchanged.  Wrong-password
/// detection relies on the 12-byte encryption header check byte
/// (the high byte of the entry's CRC-32), so a wrong password
/// surfaces as `ArchiveInvalid`.
pub fn decode_with_password(
  bytes bytes: BitArray,
  password password: String,
) -> Result(archives.Archive, error.ArchiveError) {
  decode_internal(bytes, Some(password), limit.default())
}

/// Same as `decode_with_password` but with explicit limits.
pub fn decode_with_password_and_limits(
  bytes bytes: BitArray,
  password password: String,
  limits limits: limit.Limits,
) -> Result(archives.Archive, error.ArchiveError) {
  decode_internal(bytes, Some(password), limits)
}

fn decode_internal(
  bytes: BitArray,
  password: Option(String),
  limits: limit.Limits,
) -> Result(archives.Archive, error.ArchiveError) {
  use <- bool.guard(
    when: bit_array.byte_size(bytes) > limit.max_input_bytes(limits),
    return: Error(error.ArchiveLimitExceeded(
      limit: "max_input_bytes",
      actual: bit_array.byte_size(bytes),
    )),
  )

  use eocd_offset <- result.try(locate_eocd(bytes))
  use eocd <- result.try(read_eocd(bytes, eocd_offset))

  use <- bool.guard(
    when: eocd.total_entries > limit.max_members(limits),
    return: Error(error.ArchiveLimitExceeded(
      limit: "max_members",
      actual: eocd.total_entries,
    )),
  )

  use central_bits <- result.try(slice_or_error(
    bytes,
    eocd.central_offset,
    eocd.central_size,
  ))

  use entries <- result.try(parse_central_directory(
    central_bits,
    [],
    eocd.total_entries,
    bytes,
    0,
    limits,
    password,
  ))

  let base =
    archives.from_entries(format: format(), entries: list.reverse(entries))
  case eocd.comment {
    Some(c) -> Ok(archives.with_comment(base, comment: c))
    None -> Ok(base)
  }
}

/// Walk every entry once with `list.fold`, accumulating the running
/// byte offset alongside the local-file + central-directory record
/// lists.  Using `list.fold` here (instead of an explicit
/// tail-recursive helper) keeps the encoder iterative on the
/// JavaScript target, which doesn't TCO Gleam recursion and would
/// otherwise blow its call stack on archives with tens of thousands
/// of entries (and so couldn't ever build a Zip64-sized archive).
fn encode_entries(
  remaining: List(entry.Entry),
  _offset: Int,
  _local_acc: List(BitArray),
  _central_acc: List(BitArray),
  method: Method,
) -> Result(#(List(BitArray), List(BitArray)), error.ArchiveError) {
  let init = EncodeFold(offset: 0, local_acc: [], central_acc: [], error: None)
  let folded =
    list.fold(remaining, init, fn(state, entry_value) {
      case state.error {
        Some(_) -> state
        None ->
          case encode_entry(entry_value, state.offset, method) {
            Ok(#(local_record, central_record, advance)) ->
              EncodeFold(
                offset: state.offset + advance,
                local_acc: [local_record, ..state.local_acc],
                central_acc: [central_record, ..state.central_acc],
                error: None,
              )
            Error(e) -> EncodeFold(..state, error: Some(e))
          }
      }
    })
  case folded.error {
    Some(e) -> Error(e)
    None ->
      Ok(#(list.reverse(folded.local_acc), list.reverse(folded.central_acc)))
  }
}

type EncodeFold {
  EncodeFold(
    offset: Int,
    local_acc: List(BitArray),
    central_acc: List(BitArray),
    error: Option(error.ArchiveError),
  )
}

fn encode_entry(
  value: entry.Entry,
  offset: Int,
  method: Method,
) -> Result(#(BitArray, BitArray, Int), error.ArchiveError) {
  let kind = entry.kind(value)
  let raw_path = entry.to_string(entry.path(value))

  use <- bool.guard(
    when: kind == entry.Symlink || kind == entry.Hardlink,
    return: Error(error.ArchiveEntryRejected(
      path: raw_path,
      reason: "ZIP encode currently supports files and directories only",
    )),
  )

  let canonical_path = case kind {
    entry.Directory -> ensure_trailing_slash(raw_path)
    _ -> raw_path
  }

  let name_bytes = bit_array.from_string(canonical_path)
  let name_length = bit_array.byte_size(name_bytes)

  use <- bool.guard(
    when: name_length > 65_535,
    return: Error(error.ArchiveEntryRejected(
      path: canonical_path,
      reason: "ZIP entry name longer than 65535 bytes",
    )),
  )

  let raw_body = case kind {
    entry.Directory -> <<>>
    _ -> entry.body(value)
  }

  let uncomp_size = bit_array.byte_size(raw_body)
  let crc = case kind {
    entry.Directory -> 0
    _ -> checksum.crc32(raw_body)
  }

  let entry_method = case kind {
    entry.Directory -> store()
    _ -> method
  }

  use #(method_code, compressed_body) <- result.try(case entry_method.name {
    "store" -> Ok(#(method_store, raw_body))
    "deflate" ->
      deflate_with_level(raw_body, entry_method.inner_codec)
      |> result.map(fn(b) { #(method_deflate, b) })
      |> result.map_error(codec_to_archive_error(_, canonical_path))
    "bzip2" ->
      bzip2.encode(bytes: raw_body)
      |> result.map(fn(b) { #(method_bzip2, b) })
      |> result.map_error(codec_to_archive_error(_, canonical_path))
    "lzma" -> Ok(#(method_lzma, encode_pkware_lzma(raw_body)))
    "zstd" ->
      zstd.encode(bytes: raw_body)
      |> result.map(fn(b) { #(method_zstd, b) })
      |> result.map_error(codec_to_archive_error(_, canonical_path))
    "xz" ->
      xz.encode(bytes: raw_body)
      |> result.map(fn(b) { #(method_xz, b) })
      |> result.map_error(codec_to_archive_error(_, canonical_path))
    other -> Error(error.ArchiveNotImplemented(feature: "ZIP method " <> other))
  })

  let comp_size = bit_array.byte_size(compressed_body)

  // CRC32 and external attributes never need Zip64 — they're 32-bit
  // values per spec.
  use _ <- result.try(check_u32(crc, "crc32"))

  let metadata = entry.metadata(value)
  let mode = entry.mode(metadata)
  let external_attrs = case kind {
    entry.Directory ->
      int.bitwise_or(external_attr_dir, int.bitwise_shift_left(mode, 16))
    _ -> int.bitwise_shift_left(mode, 16)
  }
  use _ <- result.try(check_u32(external_attrs, "external_attributes"))

  // Decide whether the per-entry record needs a Zip64 extra field.
  // The local file header carries comp_size + uncomp_size; if either
  // overflows we put 0xFFFFFFFF in the legacy 32-bit slot and stash
  // the real 8-byte values in a Zip64 extra (header_id 0x0001).  The
  // central-directory record additionally tracks the local-header
  // offset, which can overflow even when the sizes don't.
  let local_needs_zip64 = uncomp_size > u32_max || comp_size > u32_max
  let central_needs_zip64 = local_needs_zip64 || offset > u32_max

  let local_uncomp_slot = case uncomp_size > u32_max {
    True -> u32_max
    False -> uncomp_size
  }
  let local_comp_slot = case comp_size > u32_max {
    True -> u32_max
    False -> comp_size
  }
  let central_offset_slot = case offset > u32_max {
    True -> u32_max
    False -> offset
  }

  // Derive per-entry timestamp fields from `entry.modified_at_unix`.
  // The DOS pair is written into the fixed-width header slots; when
  // the entry has a usable mtime we additionally emit an InfoZIP
  // Extended Timestamp extra (header_id 0x5455) so the original
  // 1-second-resolution Unix value survives the 2-second DOS rounding
  // and the pre-1980 / post-2107 clamping.
  let mtime_unix = entry.modified_at_unix(metadata)
  let #(dos_time, dos_date) = unix_to_dos_pair(mtime_unix)
  let unix_ts_extra = case mtime_unix > 0 {
    True -> build_unix_ts_extra_mtime(mtime_unix)
    False -> <<>>
  }

  let zip64_local_extra = case local_needs_zip64 {
    False -> <<>>
    True ->
      // The local Zip64 extra MUST include BOTH size fields per
      // APPNOTE §4.5.3, regardless of which one triggered the
      // overflow.
      build_zip64_extra(Some(uncomp_size), Some(comp_size), None)
  }
  let zip64_central_extra = case central_needs_zip64 {
    False -> <<>>
    True ->
      build_zip64_extra(
        case uncomp_size > u32_max {
          True -> Some(uncomp_size)
          False -> None
        },
        case comp_size > u32_max {
          True -> Some(comp_size)
          False -> None
        },
        case offset > u32_max {
          True -> Some(offset)
          False -> None
        },
      )
  }
  // Concatenate Zip64 extras (when present) with the Extended
  // Timestamp extra.  APPNOTE.TXT does not mandate any ordering
  // between extra fields, but it's conventional to write Zip64 first
  // because some legacy decoders bail at the first unknown id.
  let local_extra = bit_array.concat([zip64_local_extra, unix_ts_extra])
  let central_extra = bit_array.concat([zip64_central_extra, unix_ts_extra])

  let version_needed = case
    local_needs_zip64 || central_needs_zip64,
    method_code
  {
    True, _ -> version_needed_zip64
    False, m if m == method_deflate -> version_needed_deflate
    False, m if m == method_bzip2 -> version_needed_bzip2
    False, m if m == method_lzma -> version_needed_lzma_family
    False, m if m == method_zstd -> version_needed_lzma_family
    False, m if m == method_xz -> version_needed_lzma_family
    False, _ -> version_needed_store
  }

  // PKZIP general purpose flag bit 1 means "the LZMA stream omits the
  // EOS marker and the decoder must rely on the central-directory
  // uncompressed size to know when to stop."  Our LZMA encoder is
  // literal-only and never emits an EOS marker so we always set the
  // bit when the method is LZMA.
  //
  // Bit 11 is the Language Encoding Flag (a.k.a. EFS bit, APPNOTE
  // §4.4.4): when set, the entry's filename and comment are encoded
  // as UTF-8 rather than the historical CP437.  packkit's encoder
  // always emits filenames as UTF-8, but ASCII filenames are
  // byte-identical to CP437, so we only set bit 11 when the name
  // actually contains bytes ≥ 0x80 — keeping output for ASCII names
  // bit-stable against the pre-EFS encoder.
  let lzma_flag_bit = case method_code {
    m if m == method_lzma -> 0x02
    _ -> 0
  }
  let efs_flag_bit = case name_needs_utf8_flag(name_bytes) {
    True -> 0x0800
    False -> 0x00
  }
  let gp_flag = int.bitwise_or(lzma_flag_bit, efs_flag_bit)

  let local_header =
    bit_array.concat([
      le32(local_file_signature),
      le16(version_needed),
      le16(gp_flag),
      le16(method_code),
      le16(dos_time),
      le16(dos_date),
      le32(crc),
      le32(local_comp_slot),
      le32(local_uncomp_slot),
      le16(name_length),
      le16(bit_array.byte_size(local_extra)),
      name_bytes,
      local_extra,
    ])

  let local_record = bit_array.concat([local_header, compressed_body])
  let local_record_size = bit_array.byte_size(local_record)

  let central_record =
    bit_array.concat([
      le32(central_directory_signature),
      le16(version_made_by_unix),
      le16(version_needed),
      le16(gp_flag),
      le16(method_code),
      le16(dos_time),
      le16(dos_date),
      le32(crc),
      le32(local_comp_slot),
      le32(local_uncomp_slot),
      le16(name_length),
      le16(bit_array.byte_size(central_extra)),
      le16(0),
      le16(0),
      le16(0),
      le32(external_attrs),
      le32(central_offset_slot),
      name_bytes,
      central_extra,
    ])

  Ok(#(local_record, central_record, local_record_size))
}

// -- MS-DOS date/time <-> Unix seconds -------------------------------
//
// The DOS time field (2 bytes LE) packs hour/minute/second as:
//   bits 0..4  : second / 2  (0..29 means 0..58 sec, 2-sec resolution)
//   bits 5..10 : minute      (0..59)
//   bits 11..15: hour        (0..23)
// The DOS date field (2 bytes LE) packs year/month/day as:
//   bits 0..4  : day         (1..31)
//   bits 5..8  : month       (1..12)
//   bits 9..15 : year - 1980 (0..127 → 1980..2107 inclusive)
//
// The conversion algorithms are Howard Hinnant's date routines from
// http://howardhinnant.github.io/date_algorithms.html, adapted to
// integer arithmetic.  They are exact for any civil date in the
// supported window and use no calendar tables.
fn unix_to_dos_pair(seconds: Int) -> #(Int, Int) {
  case seconds < dos_epoch_unix || seconds >= dos_epoch_ceiling_unix {
    True -> #(default_mtime_dos, default_mdate_dos)
    False -> {
      let days = seconds / 86_400
      let sod = seconds - days * 86_400
      let #(year, month, day) = civil_from_days(days)
      let hour = sod / 3600
      let minute = { sod - hour * 3600 } / 60
      let second = sod - hour * 3600 - minute * 60
      let dos_time =
        int.bitwise_or(
          int.bitwise_or(
            int.bitwise_shift_left(hour, 11),
            int.bitwise_shift_left(minute, 5),
          ),
          second / 2,
        )
      let dos_date =
        int.bitwise_or(
          int.bitwise_or(
            int.bitwise_shift_left(year - 1980, 9),
            int.bitwise_shift_left(month, 5),
          ),
          day,
        )
      #(dos_time, dos_date)
    }
  }
}

fn dos_pair_to_unix(time_code: Int, date_code: Int) -> Int {
  let day = int.bitwise_and(date_code, 0x1F)
  let month = int.bitwise_and(int.bitwise_shift_right(date_code, 5), 0x0F)
  let year = int.bitwise_shift_right(date_code, 9) + 1980
  let second_pair = int.bitwise_and(time_code, 0x1F)
  let minute = int.bitwise_and(int.bitwise_shift_right(time_code, 5), 0x3F)
  let hour = int.bitwise_shift_right(time_code, 11)
  // DOS allows day=0 / month=0 only on the "no mtime" sentinel pair.
  // Anything else with day < 1 or month < 1 is a producer bug; fall
  // back to the DOS epoch rather than feeding bogus values to
  // `days_from_civil`.
  case day < 1 || month < 1 || month > 12 {
    True -> dos_epoch_unix
    False -> {
      let days = days_from_civil(year, month, day)
      days * 86_400 + hour * 3600 + minute * 60 + second_pair * 2
    }
  }
}

// civil_from_days: convert a count of days since 1970-01-01 into a
// proleptic-Gregorian (year, month, day) triple.  Valid for any int.
//
// The local names (`days_shifted`, `day_of_era`, `year_of_era`,
// `march_year`, `day_of_year`, `month_prime`) are spelled out in
// full to keep the lint happy; the original Hinnant paper uses the
// terse mnemonics (z / doe / yoe / y / doy / mp) and the comments
// preserve the mapping so the algorithm stays auditable.
fn civil_from_days(z: Int) -> #(Int, Int, Int) {
  // Shift the epoch to 0000-03-01 so the leap-year math falls on a
  // year boundary; the +719_468 lifts 1970-01-01 to that origin.
  let days_shifted = z + 719_468
  let era = case days_shifted >= 0 {
    True -> days_shifted / 146_097
    False -> { days_shifted - 146_096 } / 146_097
  }
  let day_of_era = days_shifted - era * 146_097
  let year_of_era =
    {
      day_of_era
      - day_of_era
      / 1460
      + day_of_era
      / 36_524
      - day_of_era
      / 146_096
    }
    / 365
  let march_year = year_of_era + era * 400
  let day_of_year =
    day_of_era - { 365 * year_of_era + year_of_era / 4 - year_of_era / 100 }
  let month_prime = { 5 * day_of_year + 2 } / 153
  let day = day_of_year - { 153 * month_prime + 2 } / 5 + 1
  let month = case month_prime < 10 {
    True -> month_prime + 3
    False -> month_prime - 9
  }
  let year = case month <= 2 {
    True -> march_year + 1
    False -> march_year
  }
  #(year, month, day)
}

// days_from_civil: inverse of `civil_from_days`.  Returns days since
// 1970-01-01.
fn days_from_civil(year: Int, month: Int, day: Int) -> Int {
  let march_year = case month <= 2 {
    True -> year - 1
    False -> year
  }
  let era = case march_year >= 0 {
    True -> march_year / 400
    False -> { march_year - 399 } / 400
  }
  let year_of_era = march_year - era * 400
  let month_prime = case month > 2 {
    True -> month - 3
    False -> month + 9
  }
  let day_of_year = { 153 * month_prime + 2 } / 5 + day - 1
  let day_of_era =
    year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year
  era * 146_097 + day_of_era - 719_468
}

// -- InfoZIP Extended Timestamp extra field --------------------------

// Build a UT extra carrying mtime only.  Layout per InfoZIP
// proginfo/extrafld.txt:
//   header_id (LE16)   : 0x5455
//   data_size (LE16)   : 1 + 4 * popcount(flags)
//   flags     (1 byte) : bit 0 = mtime present, bit 1 = atime, bit 2 = ctime
//   mtime     (LE32)   : signed Unix seconds (when flag bit 0 set)
//   [atime / ctime follow only in the local extra; the central extra
//    contains mtime only.]
// We emit the central form (mtime only) in both places.  The
// decoder side already handles arbitrary flag combinations.
fn build_unix_ts_extra_mtime(mtime: Int) -> BitArray {
  let body = <<unix_ts_flag_mtime, mtime:little-size(32)>>
  bit_array.concat([
    le16(unix_ts_extra_id),
    le16(bit_array.byte_size(body)),
    body,
  ])
}

// Scan the extras blob for a UT field and return the mtime if the
// field is present and its `mtime` flag bit is set.  Other flag bits
// (atime, ctime) are skipped — packkit's entry model has no atime /
// ctime fields yet.
fn find_unix_ts_extra_mtime(extra: BitArray) -> Option(Int) {
  case find_extra_field(extra, unix_ts_extra_id) {
    Error(_) -> None
    Ok(body) ->
      case body {
        <<flags, mtime:little-size(32), _:bytes>> ->
          case
            int.bitwise_and(flags, unix_ts_flag_mtime) == unix_ts_flag_mtime
          {
            True -> Some(mtime)
            False -> None
          }
        _ -> None
      }
  }
}

/// Build a Zip64 extended-information extra-field record.  Each of
/// `uncomp` / `comp` / `local_offset` is `Some(value)` when the
/// corresponding 32-bit slot has been replaced with the 0xFFFFFFFF
/// sentinel; the function packs the present values in the order
/// APPNOTE.TXT §4.5.3 prescribes.
fn build_zip64_extra(
  uncomp: Option(Int),
  comp: Option(Int),
  local_offset: Option(Int),
) -> BitArray {
  let body =
    bit_array.concat([
      case uncomp {
        Some(v) -> le64(v)
        None -> <<>>
      },
      case comp {
        Some(v) -> le64(v)
        None -> <<>>
      },
      case local_offset {
        Some(v) -> le64(v)
        None -> <<>>
      },
    ])
  let body_size = bit_array.byte_size(body)
  bit_array.concat([le16(zip64_extra_id), le16(body_size), body])
}

fn ensure_trailing_slash(value: String) -> String {
  case string.ends_with(value, "/") {
    True -> value
    False -> value <> "/"
  }
}

type EocdRecord {
  EocdRecord(
    total_entries: Int,
    central_offset: Int,
    central_size: Int,
    comment: Option(String),
  )
}

fn locate_eocd(bytes: BitArray) -> Result(Int, error.ArchiveError) {
  let size = bit_array.byte_size(bytes)
  case size < 22 {
    True -> Error(error.ArchiveInvalid(message: "ZIP stream too short"))
    False -> {
      let start = case size - 22 - 65_535 < 0 {
        True -> 0
        False -> size - 22 - 65_535
      }
      scan_eocd(bytes, size - 22, start)
    }
  }
}

fn scan_eocd(
  bytes: BitArray,
  position: Int,
  floor: Int,
) -> Result(Int, error.ArchiveError) {
  case position < floor {
    True -> Error(error.ArchiveInvalid(message: "missing ZIP EOCD signature"))
    False ->
      case bit_array.slice(bytes, position, 4) {
        Ok(slice) ->
          case read_le32(slice) {
            Ok(value) if value == eocd_signature -> Ok(position)
            _ -> scan_eocd(bytes, position - 1, floor)
          }
        Error(_) -> scan_eocd(bytes, position - 1, floor)
      }
  }
}

fn read_eocd(
  bytes: BitArray,
  position: Int,
) -> Result(EocdRecord, error.ArchiveError) {
  use total_entries <- result.try(read_le16_at(bytes, position + 10))
  use central_size <- result.try(read_le32_at(bytes, position + 12))
  use central_offset <- result.try(read_le32_at(bytes, position + 16))
  use comment_length <- result.try(read_le16_at(bytes, position + 20))
  use comment <- result.try(case comment_length {
    0 -> Ok(None)
    n -> {
      use comment_bits <- result.try(slice_or_error(bytes, position + 22, n))
      case bit_array.to_string(comment_bits) {
        Ok(text) -> Ok(Some(text))
        Error(_) ->
          Error(error.ArchiveInvalid(
            message: "non-UTF-8 archive comment in ZIP EOCD",
          ))
      }
    }
  })

  // When any of the 16-/32-bit slots carries its Zip64 sentinel the
  // real value lives in the Zip64 EOCD record reached via the Zip64
  // EOCD locator placed at `position - 20`.  Any non-sentinel value
  // in the standard slot wins (the spec lets implementations write
  // both forms for backward compatibility).
  let needs_zip64 =
    total_entries == u16_max
    || central_size == u32_max
    || central_offset == u32_max
  use #(total_entries, central_size, central_offset) <- result.try(
    case needs_zip64 {
      False -> Ok(#(total_entries, central_size, central_offset))
      True -> {
        use #(zip64_entries, zip64_size, zip64_offset) <- result.try(
          read_zip64_eocd_from_locator(bytes, position),
        )
        Ok(
          #(
            case total_entries == u16_max {
              True -> zip64_entries
              False -> total_entries
            },
            case central_size == u32_max {
              True -> zip64_size
              False -> central_size
            },
            case central_offset == u32_max {
              True -> zip64_offset
              False -> central_offset
            },
          ),
        )
      }
    },
  )

  Ok(EocdRecord(
    total_entries: total_entries,
    central_offset: central_offset,
    central_size: central_size,
    comment: comment,
  ))
}

/// Locate and parse the Zip64 EOCD record.  The locator sits in the
/// 20 bytes immediately preceding the standard EOCD signature; the
/// 8-byte little-endian field at offset 8 of the locator points to
/// the Zip64 EOCD record itself.
fn read_zip64_eocd_from_locator(
  bytes: BitArray,
  eocd_position: Int,
) -> Result(#(Int, Int, Int), error.ArchiveError) {
  case eocd_position < 20 {
    True ->
      Error(error.ArchiveInvalid(
        message: "ZIP EOCD sentinel without Zip64 locator (archive too short)",
      ))
    False -> {
      let locator_position = eocd_position - 20
      use locator_sig <- result.try(read_le32_at(bytes, locator_position))
      use <- bool.guard(
        when: locator_sig != zip64_eocd_locator_signature,
        return: Error(error.ArchiveInvalid(
          message: "ZIP EOCD sentinel but no Zip64 EOCD locator present",
        )),
      )
      use zip64_eocd_offset <- result.try(read_le64_at(
        bytes,
        locator_position + 8,
      ))
      read_zip64_eocd_record(bytes, zip64_eocd_offset)
    }
  }
}

fn read_zip64_eocd_record(
  bytes: BitArray,
  offset: Int,
) -> Result(#(Int, Int, Int), error.ArchiveError) {
  use signature <- result.try(read_le32_at(bytes, offset))
  use <- bool.guard(
    when: signature != zip64_eocd_signature,
    return: Error(error.ArchiveInvalid(
      message: "Zip64 EOCD signature missing at locator-pointed offset",
    )),
  )
  // Skip:
  //   +4  size of Zip64 EOCD record minus 12 (8 bytes)
  //   +12 version made by (2 bytes)
  //   +14 version needed (2 bytes)
  //   +16 this disk number (4 bytes)
  //   +20 disk with central directory start (4 bytes)
  //   +24 entries on this disk (8 bytes)
  //   +32 total entries (8 bytes)         <- want
  //   +40 central directory size (8 bytes) <- want
  //   +48 central directory offset (8 bytes) <- want
  use total_entries <- result.try(read_le64_at(bytes, offset + 32))
  use central_size <- result.try(read_le64_at(bytes, offset + 40))
  use central_offset <- result.try(read_le64_at(bytes, offset + 48))
  Ok(#(total_entries, central_size, central_offset))
}

fn parse_central_directory(
  bytes: BitArray,
  acc: List(entry.Entry),
  remaining: Int,
  full: BitArray,
  accumulated_body_bytes: Int,
  limits: limit.Limits,
  password: Option(String),
) -> Result(List(entry.Entry), error.ArchiveError) {
  case remaining {
    0 -> Ok(acc)
    _ -> {
      use signature <- result.try(read_le32_at(bytes, 0))
      use <- bool.guard(
        when: signature != central_directory_signature,
        return: Error(error.ArchiveInvalid(
          message: "missing ZIP central directory signature",
        )),
      )

      use gp_flag <- result.try(read_le16_at(bytes, 8))
      use method <- result.try(read_le16_at(bytes, 10))
      use dos_time <- result.try(read_le16_at(bytes, 12))
      use dos_date <- result.try(read_le16_at(bytes, 14))
      use crc <- result.try(read_le32_at(bytes, 16))
      use comp_size <- result.try(read_le32_at(bytes, 20))
      use uncomp_size <- result.try(read_le32_at(bytes, 24))
      use name_length <- result.try(read_le16_at(bytes, 28))
      use extra_length <- result.try(read_le16_at(bytes, 30))
      use comment_length <- result.try(read_le16_at(bytes, 32))
      use external_attrs <- result.try(read_le32_at(bytes, 38))
      use local_offset <- result.try(read_le32_at(bytes, 42))

      let name_offset = 46
      use name_bits <- result.try(slice_or_error(
        bytes,
        name_offset,
        name_length,
      ))
      use name <- result.try(bytes_to_string(name_bits))

      // Walk the extra-field block when any of the 32-bit slots is at
      // its Zip64 sentinel and pick up the real 64-bit value(s).
      use extra_bits <- result.try(slice_or_error(
        bytes,
        name_offset + name_length,
        extra_length,
      ))
      let uncomp_at_sentinel = uncomp_size == u32_max
      let comp_at_sentinel = comp_size == u32_max
      let offset_at_sentinel = local_offset == u32_max
      use #(zip64_uncomp, zip64_comp, zip64_offset) <- result.try(
        parse_zip64_extra(
          extra_bits,
          uncomp_at_sentinel,
          comp_at_sentinel,
          offset_at_sentinel,
        ),
      )
      let uncomp_size = case zip64_uncomp {
        Some(v) -> v
        None -> uncomp_size
      }
      let comp_size = case zip64_comp {
        Some(v) -> v
        None -> comp_size
      }
      let local_offset = case zip64_offset {
        Some(v) -> v
        None -> local_offset
      }

      // Resolve the entry's mtime.  The InfoZIP Extended Timestamp
      // extra (header_id 0x5455) carries the original Unix seconds at
      // full 1-second resolution; the DOS time/date fields in the
      // fixed header carry the same instant at 2-second resolution
      // and only between 1980 and 2107.  Prefer the UT extra when
      // present, otherwise reconstruct from the DOS pair.  Entries
      // with no recorded mtime are serialised as the packkit "no
      // mtime" sentinel (`default_mtime_dos`, `default_mdate_dos`);
      // short-circuit that pair back to 0 so the round-trip keeps
      // `modified_at_unix = 0` instead of rehydrating an artificial
      // 1980-01-01 00:01:02 stamp.
      let mtime_resolved = case find_unix_ts_extra_mtime(extra_bits) {
        Some(v) if v >= 0 -> v
        _ ->
          case dos_time == default_mtime_dos && dos_date == default_mdate_dos {
            True -> 0
            False -> dos_pair_to_unix(dos_time, dos_date)
          }
      }

      use <- bool.guard(
        when: string.byte_size(name) > limit.max_entry_name_bytes(limits),
        return: Error(error.ArchiveLimitExceeded(
          limit: "max_entry_name_bytes",
          actual: string.byte_size(name),
        )),
      )

      let cleaned_name = strip_trailing_slash(name)
      let depth = path_depth(cleaned_name)
      use <- bool.guard(
        when: depth > limit.max_entry_depth(limits),
        return: Error(error.ArchiveLimitExceeded(
          limit: "max_entry_depth",
          actual: depth,
        )),
      )

      use <- bool.guard(
        when: !is_supported_method(method),
        return: Error(error.ArchiveNotImplemented(
          feature: "ZIP method " <> int.to_string(method),
        )),
      )

      use entry_value <- result.try(read_local_entry(
        full,
        local_offset,
        name,
        crc,
        uncomp_size,
        comp_size,
        external_attrs,
        limits,
        gp_flag,
        password,
        mtime_resolved,
      ))

      // Adversarial archives can pack many independently-bounded
      // deflate streams whose catenated decompressed bodies exceed
      // `max_output_bytes`.  The per-entry deflate decoder caps
      // each body individually; the running total here folds every
      // entry's body size into the same limit so a zip bomb built
      // from many entries fails as soon as the cumulative output
      // size crosses the threshold instead of after all entries
      // have been materialised.
      let next_total =
        accumulated_body_bytes + bit_array.byte_size(entry.body(entry_value))
      use <- bool.guard(
        when: next_total > limit.max_output_bytes(limits),
        return: Error(error.ArchiveLimitExceeded(
          limit: "max_output_bytes",
          actual: next_total,
        )),
      )

      let record_size = 46 + name_length + extra_length + comment_length
      let next_bits = case
        bit_array.slice(
          bytes,
          record_size,
          bit_array.byte_size(bytes) - record_size,
        )
      {
        Ok(value) -> value
        Error(_) -> <<>>
      }

      parse_central_directory(
        next_bits,
        [entry_value, ..acc],
        remaining - 1,
        full,
        next_total,
        limits,
        password,
      )
    }
  }
}

fn read_local_entry(
  full: BitArray,
  local_offset: Int,
  name: String,
  expected_crc: Int,
  uncomp_size: Int,
  comp_size: Int,
  external_attrs: Int,
  limits: limit.Limits,
  gp_flag: Int,
  password: Option(String),
  mtime_unix: Int,
) -> Result(entry.Entry, error.ArchiveError) {
  use signature <- result.try(read_le32_at(full, local_offset))
  use <- bool.guard(
    when: signature != local_file_signature,
    return: Error(error.ArchiveInvalid(
      message: "missing local file header signature",
    )),
  )

  let encrypted = int.bitwise_and(gp_flag, 1) == 1
  let strong_encrypted = int.bitwise_and(gp_flag, 0x40) != 0
  use <- bool.guard(
    when: strong_encrypted,
    return: Error(error.ArchiveNotImplemented(
      feature: "ZIP strong-encryption (gp flag bit 6)",
    )),
  )

  use method <- result.try(read_le16_at(full, local_offset + 8))
  use <- bool.guard(
    when: !is_supported_method(method),
    return: Error(error.ArchiveNotImplemented(
      feature: "ZIP method " <> int.to_string(method),
    )),
  )

  use local_name_length <- result.try(read_le16_at(full, local_offset + 26))
  use local_extra_length <- result.try(read_le16_at(full, local_offset + 28))
  use local_uncomp <- result.try(read_le32_at(full, local_offset + 22))
  use local_comp <- result.try(read_le32_at(full, local_offset + 18))

  // The local header carries its own copy of the comp/uncomp sizes;
  // when they're at the 32-bit sentinel its Zip64 extra (header_id
  // 0x0001) MUST include BOTH size fields per APPNOTE §4.5.3.  We
  // prefer the central-directory values (passed in) but fall back to
  // whatever the local Zip64 extra carries when the caller's values
  // are themselves at sentinel — keeps the decoder robust against
  // archives that only encode the real sizes in one place.
  use local_extra_bits <- result.try(slice_or_error(
    full,
    local_offset + 30 + local_name_length,
    local_extra_length,
  ))
  use #(local_zip64_uncomp, local_zip64_comp, _) <- result.try(
    parse_zip64_extra(
      local_extra_bits,
      local_uncomp == u32_max,
      local_comp == u32_max,
      False,
    ),
  )
  let uncomp_size = case uncomp_size, local_zip64_uncomp {
    n, Some(v) if n == u32_max -> v
    n, _ -> n
  }
  let comp_size = case comp_size, local_zip64_comp {
    n, Some(v) if n == u32_max -> v
    n, _ -> n
  }

  let data_offset = local_offset + 30 + local_name_length + local_extra_length

  // Resolve any PKWARE traditional encryption layer up-front so the
  // method-specific branch always sees the plain compressed bytes.
  // `comp_size` already accounts for the 12-byte encryption header
  // for encrypted entries (and equals `uncomp_size` for unencrypted
  // stored entries), so it's the right total-size value to hand to
  // the resolver in every case.
  use plain_slice <- result.try(resolve_pkware_decryption(
    full,
    data_offset,
    comp_size,
    encrypted,
    expected_crc,
    password,
    name,
  ))
  let data_offset = plain_slice.0
  let comp_size = plain_slice.1
  let body_source = plain_slice.2

  use body <- result.try(case method {
    m if m == method_store ->
      slice_or_error(body_source, data_offset, uncomp_size)
    m if m == method_deflate -> {
      use compressed <- result.try(slice_or_error(
        body_source,
        data_offset,
        comp_size,
      ))
      deflate.decode_with_limits(bytes: compressed, limits: limits)
      |> result.map_error(codec_to_archive_error(_, name))
    }
    m if m == method_bzip2 -> {
      use compressed <- result.try(slice_or_error(
        body_source,
        data_offset,
        comp_size,
      ))
      bzip2.decode_with_limits(bytes: compressed, limits: limits)
      |> result.map_error(codec_to_archive_error(_, name))
    }
    m if m == method_lzma -> {
      use compressed <- result.try(slice_or_error(
        body_source,
        data_offset,
        comp_size,
      ))
      decode_pkware_lzma(compressed, uncomp_size, limits)
      |> result.map_error(codec_to_archive_error(_, name))
    }
    m if m == method_zstd -> {
      use compressed <- result.try(slice_or_error(
        body_source,
        data_offset,
        comp_size,
      ))
      zstd.decode_with_limits(bytes: compressed, limits: limits)
      |> result.map_error(codec_to_archive_error(_, name))
    }
    m if m == method_xz -> {
      use compressed <- result.try(slice_or_error(
        body_source,
        data_offset,
        comp_size,
      ))
      xz.decode_with_limits(bytes: compressed, limits: limits)
      |> result.map_error(codec_to_archive_error(_, name))
    }
    other ->
      Error(error.ArchiveNotImplemented(
        feature: "ZIP method " <> int.to_string(other),
      ))
  })

  use <- bool.guard(
    when: checksum.crc32(body) != expected_crc,
    return: Error(error.ArchiveInvalid(message: "ZIP CRC32 mismatch")),
  )

  let is_directory = string.ends_with(name, "/")
  let mode =
    int.bitwise_and(int.bitwise_shift_right(external_attrs, 16), 0xFFFF)

  let apply_metadata = fn(e: entry.Entry) -> entry.Entry {
    let with_mode = case mode {
      0 -> e
      _ -> entry.with_mode(e, mode: mode)
    }
    case mtime_unix > 0 {
      True -> entry.with_modified_at(with_mode, unix_seconds: mtime_unix)
      False -> with_mode
    }
  }

  case is_directory {
    True ->
      entry.directory_checked(path: strip_trailing_slash(name))
      |> result.map_error(entry_error_to_archive_error(_, name))
      |> result.map(apply_metadata)
    False ->
      entry.file_checked(path: name, body: body)
      |> result.map_error(entry_error_to_archive_error(_, name))
      |> result.map(apply_metadata)
  }
}

// ============================================================
// PKWARE "traditional" ZIP encryption (a.k.a. ZipCrypto)
//
// Each encrypted entry has a 12-byte encryption header prepended to
// its compressed payload.  The cipher is a stream cipher seeded by
// three 32-bit keys; the keys are mixed by the password byte-by-byte
// at init, then by each plaintext byte during streaming.  The 12th
// decrypted header byte must equal the high byte of the entry's
// CRC-32 (per APPNOTE §6.0).  We use that check to surface a typed
// "wrong password" error rather than handing the codec random bytes.
// ============================================================

type PkwareKeys {
  PkwareKeys(key0: Int, key1: Int, key2: Int)
}

fn pkware_initial_keys() -> PkwareKeys {
  PkwareKeys(key0: 0x12345678, key1: 0x23456789, key2: 0x34567890)
}

// Derive the per-entry key state from a password.  Equivalent to
// running `update_keys` over every password byte with the initial
// triple.
fn pkware_keys_from_password(password: String) -> PkwareKeys {
  pkware_seed_loop(pkware_initial_keys(), bit_array.from_string(password))
}

fn pkware_seed_loop(keys: PkwareKeys, password: BitArray) -> PkwareKeys {
  case password {
    <<b, rest:bytes>> -> pkware_seed_loop(pkware_update_keys(keys, b), rest)
    _ -> keys
  }
}

fn pkware_update_keys(keys: PkwareKeys, byte: Int) -> PkwareKeys {
  let new_key0 = pkware_crc32_byte(keys.key0, byte)
  // key1 = (key1 + (key0 & 0xFF)) * 134775813 + 1 mod 2^32
  let added = int.bitwise_and(new_key0, 0xFF) + keys.key1
  let mixed = added * 134_775_813 + 1
  let new_key1 = int.bitwise_and(mixed, 0xFFFFFFFF)
  let top = int.bitwise_and(int.bitwise_shift_right(new_key1, 24), 0xFF)
  let new_key2 = pkware_crc32_byte(keys.key2, top)
  PkwareKeys(key0: new_key0, key1: new_key1, key2: new_key2)
}

// `(crc >> 8) ^ crc32_table[(crc ^ byte) & 0xFF]`, where the lookup
// is the IEEE 802.3 / PNG / ZIP CRC-32 table (reflected polynomial
// 0xEDB88320).  Computed on the fly rather than memoised — the cipher
// only runs once per encrypted byte and the table builder is 8 small
// iterations so the per-byte cost stays bounded.
fn pkware_crc32_byte(crc: Int, byte: Int) -> Int {
  let idx = int.bitwise_and(int.bitwise_exclusive_or(crc, byte), 0xFF)
  let folded = pkware_crc32_fold(idx, 8)
  int.bitwise_exclusive_or(int.bitwise_shift_right(crc, 8), folded)
}

fn pkware_crc32_fold(value: Int, rounds: Int) -> Int {
  case rounds {
    0 -> value
    _ -> {
      let next = case int.bitwise_and(value, 1) {
        1 ->
          int.bitwise_exclusive_or(
            int.bitwise_shift_right(value, 1),
            0xEDB88320,
          )
        _ -> int.bitwise_shift_right(value, 1)
      }
      pkware_crc32_fold(next, rounds - 1)
    }
  }
}

fn pkware_decrypt_byte(keys: PkwareKeys, cipher: Int) -> #(Int, PkwareKeys) {
  // temp = key2 | 2; plain = cipher ^ ((temp * (temp ^ 1)) >> 8) & 0xFF
  let temp = int.bitwise_or(keys.key2, 2)
  let prod = temp * int.bitwise_exclusive_or(temp, 1)
  let mask = int.bitwise_and(int.bitwise_shift_right(prod, 8), 0xFF)
  let plain = int.bitwise_exclusive_or(cipher, mask)
  let next_keys = pkware_update_keys(keys, plain)
  #(plain, next_keys)
}

fn pkware_decrypt_bytes(
  keys: PkwareKeys,
  cipher: BitArray,
  acc: BitArray,
) -> #(BitArray, PkwareKeys) {
  case cipher {
    <<b, rest:bytes>> -> {
      let #(plain, keys) = pkware_decrypt_byte(keys, b)
      pkware_decrypt_bytes(keys, rest, <<acc:bits, plain>>)
    }
    _ -> #(acc, keys)
  }
}

// Resolve any PKWARE-encrypted entry to its plain compressed bytes.
// Returns a triple `#(data_offset, comp_size, source_buffer)` so the
// caller can keep slicing through the existing helpers without
// caring whether the buffer is the original archive or a fresh
// plaintext buffer.  For unencrypted entries the original archive
// is returned unchanged; for encrypted entries the leading 12-byte
// header is consumed, verified, and stripped.
fn resolve_pkware_decryption(
  full: BitArray,
  data_offset: Int,
  total_size: Int,
  encrypted: Bool,
  expected_crc: Int,
  password: Option(String),
  name: String,
) -> Result(#(Int, Int, BitArray), error.ArchiveError) {
  case encrypted, password {
    False, _ -> Ok(#(data_offset, total_size, full))
    True, None ->
      Error(error.ArchiveNotImplemented(
        feature: "encrypted ZIP entry \""
        <> name
        <> "\" (use decode_with_password)",
      ))
    True, Some(pwd) -> {
      use raw <- result.try(slice_or_error(full, data_offset, total_size))
      use #(header_cipher, payload_cipher) <- result.try(split_enc_header(
        raw,
        total_size,
      ))
      let keys = pkware_keys_from_password(pwd)
      let #(header_plain, keys) =
        pkware_decrypt_bytes(keys, header_cipher, <<>>)
      let check = pkware_last_byte(header_plain)
      let expected_check =
        int.bitwise_and(int.bitwise_shift_right(expected_crc, 24), 0xFF)
      use <- bool.guard(
        when: check != expected_check,
        return: Error(error.ArchiveInvalid(
          message: "ZIP wrong password or corrupt encryption header for \""
          <> name
          <> "\"",
        )),
      )
      let #(payload_plain, _keys) =
        pkware_decrypt_bytes(keys, payload_cipher, <<>>)
      Ok(#(0, total_size - 12, payload_plain))
    }
  }
}

// Split the encrypted slice into its 12-byte header and the payload
// that follows.  Pulled out so `resolve_pkware_decryption` doesn't
// stack `case bit_array.slice` branches and trip the deep-nesting
// lint.
fn split_enc_header(
  raw: BitArray,
  total_size: Int,
) -> Result(#(BitArray, BitArray), error.ArchiveError) {
  case bit_array.slice(raw, 0, 12), bit_array.slice(raw, 12, total_size - 12) {
    Ok(h), Ok(p) -> Ok(#(h, p))
    Error(_), _ ->
      Error(error.ArchiveInvalid(
        message: "ZIP encryption header truncated (need ≥ 12 bytes)",
      ))
    _, Error(_) ->
      Error(error.ArchiveInvalid(
        message: "ZIP encrypted entry payload truncated",
      ))
  }
}

fn pkware_last_byte(bytes: BitArray) -> Int {
  pkware_last_byte_loop(bytes, 0)
}

fn pkware_last_byte_loop(bytes: BitArray, last: Int) -> Int {
  case bytes {
    <<b, rest:bytes>> -> pkware_last_byte_loop(rest, b)
    _ -> last
  }
}

/// Decode a ZIP method 14 PKWARE LZMA payload to its plain bytes.
///
/// PKZIP APPNOTE.TXT §5.8 lays the wrapper out as:
///   +0  1 byte    LZMA SDK major version
///   +1  1 byte    LZMA SDK minor version
///   +2  2 bytes   Size of the LZMA property block (LE, normally 5)
///   +4  N bytes   LZMA1 property block (1 properties byte + 4 little-
///                 endian dictionary-size bytes when N == 5)
///   +4+N         Raw LZMA1 range-coded payload (the byte stream
///                 expected by `packkit/internal/lzma.new`)
///
/// We forward the property byte to `lzma.properties_of_byte`, the
/// remaining range-coded bytes to `lzma.new`, and ask the decoder
/// for exactly the central-directory uncompressed size — the EOS
/// marker (when present in payload-bit-1 = 0 streams) terminates
/// inside the range coder and the size-limited loop covers the
/// payload-bit-1 = 1 case.  The dictionary-size field is informational
/// for the wrapper; the LZMA decoder allocates its window lazily.
fn decode_pkware_lzma(
  compressed: BitArray,
  uncomp_size: Int,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  use #(prop_size, prop_block, payload) <- result.try(parse_pkware_lzma_header(
    compressed,
  ))
  use <- bool.guard(
    when: prop_size != 5,
    return: Error(error.CodecInvalidData(
      message: "PKWARE LZMA wrapper property size must be 5",
    )),
  )
  use props <- result.try(parse_pkware_lzma_props(prop_block))
  use <- bool.guard(
    when: uncomp_size > limit.max_output_bytes(limits),
    return: Error(error.CodecLimitExceeded(
      limit: "max_output_bytes",
      actual: uncomp_size,
    )),
  )
  use decoder <- result.try(lzma.new(
    payload,
    props,
    limit.max_output_bytes(limits),
  ))
  use #(decoded, _state) <- result.try(lzma.decode_into(decoder, uncomp_size))
  Ok(decoded)
}

fn parse_pkware_lzma_header(
  compressed: BitArray,
) -> Result(#(Int, BitArray, BitArray), error.CodecError) {
  case compressed {
    <<_major, _minor, prop_size:little-unsigned-size(16), rest:bytes>> -> {
      let rest_size = bit_array.byte_size(rest)
      use <- bool.guard(
        when: rest_size < prop_size,
        return: Error(error.CodecInvalidData(
          message: "PKWARE LZMA wrapper truncated property block",
        )),
      )
      let prop_slice = bit_array.slice(rest, 0, prop_size)
      let payload_slice =
        bit_array.slice(rest, prop_size, rest_size - prop_size)
      case prop_slice, payload_slice {
        Ok(prop_block), Ok(payload) -> Ok(#(prop_size, prop_block, payload))
        _, _ ->
          Error(error.CodecInvalidData(
            message: "PKWARE LZMA wrapper slice out of range",
          ))
      }
    }
    _ ->
      Error(error.CodecInvalidData(
        message: "PKWARE LZMA wrapper missing header",
      ))
  }
}

fn parse_pkware_lzma_props(
  prop_block: BitArray,
) -> Result(lzma.Properties, error.CodecError) {
  case prop_block {
    <<prop_byte, _dict_size:little-unsigned-size(32)>> ->
      lzma.properties_of_byte(prop_byte)
    _ ->
      Error(error.CodecInvalidData(
        message: "PKWARE LZMA wrapper property block has wrong length",
      ))
  }
}

/// Build a PKWARE method-14 payload by gluing the 4-byte SDK preamble
/// + 5-byte property block in front of an LZMA1 raw range-coded
/// stream produced by `packkit/internal/lzma.encode_literal_only`.
/// The general-purpose flag bit 1 (set in the entry's local + central
/// headers) tells the reader to use the uncompressed size from the
/// central directory instead of looking for an in-stream EOS marker —
/// which our literal-only encoder never emits.
fn encode_pkware_lzma(plain: BitArray) -> BitArray {
  // Standard LZMA defaults (matching what `xz`/`7z` ship for new
  // archives): lc=3, lp=0, pb=2.  Dictionary size is 64 KiB; the
  // encoder does not allocate a dictionary in literal-only mode but
  // the value is part of the wrapper for downstream tools.
  let props = lzma.Properties(lc: 3, lp: 0, pb: 2)
  let stream = lzma.encode_with_lz77(bytes: plain, props: props)
  let prop_byte = lzma.properties_to_byte(props)
  let dict_size_bytes = <<0x10000:little-size(32)>>
  let preamble = <<
    // SDK version (major.minor); 20.0 (decimal) = 0x14 0x00 mirrors
    // what `xz`/`7z` emit and what the corresponding decode test
    // fixture carries.
    0x14, 0x00,
    // Property block size, always 5 for canonical LZMA1.
    0x05, 0x00,
  >>
  bit_array.concat([preamble, <<prop_byte>>, dict_size_bytes, stream])
}

fn strip_trailing_slash(value: String) -> String {
  case string.ends_with(value, "/") {
    True -> string.drop_end(value, 1)
    False -> value
  }
}

fn path_depth(name: String) -> Int {
  case name {
    "" -> 0
    _ -> list.length(string.split(name, "/"))
  }
}

fn codec_to_archive_error(
  err: error.CodecError,
  path: String,
) -> error.ArchiveError {
  case err {
    error.CodecInvalidData(message) ->
      error.ArchiveEntryRejected(
        path: path,
        reason: "deflate decode failed: " <> message,
      )
    error.CodecLimitExceeded(limit, actual) ->
      error.ArchiveLimitExceeded(limit: limit, actual: actual)
    error.CodecDictionaryRequired(_) ->
      error.ArchiveEntryRejected(
        path: path,
        reason: "deflate decode requires preset dictionary (not supported)",
      )
    error.CodecDictionaryMismatch(_) ->
      error.ArchiveEntryRejected(
        path: path,
        reason: "deflate decode preset dictionary mismatch",
      )
    error.CodecOptionUnsupported(option, codec_name) ->
      error.ArchiveEntryRejected(
        path: path,
        reason: "codec "
          <> codec_name
          <> " does not support the requested option: "
          <> option,
      )
    error.CodecNotImplemented(feature) ->
      error.ArchiveNotImplemented(feature: feature)
  }
}

fn entry_error_to_archive_error(
  err: entry.EntryError,
  path: String,
) -> error.ArchiveError {
  case err {
    entry.EmptyPath ->
      error.ArchiveEntryRejected(path: path, reason: "empty path")
    entry.AbsolutePath(_) ->
      error.ArchiveEntryRejected(path: path, reason: "absolute path")
    entry.PathTraversal(_) ->
      error.ArchiveEntryRejected(path: path, reason: "path traversal")
    entry.WindowsPath(_) ->
      error.ArchiveEntryRejected(path: path, reason: "windows path")
    entry.EmptySegment(_) ->
      error.ArchiveEntryRejected(path: path, reason: "empty segment")
    entry.DotSegment(_) ->
      error.ArchiveEntryRejected(path: path, reason: "dot segment")
    entry.ContainsNul(_) ->
      error.ArchiveEntryRejected(path: path, reason: "nul byte")
  }
}

fn slice_or_error(
  bytes: BitArray,
  offset: Int,
  width: Int,
) -> Result(BitArray, error.ArchiveError) {
  case bit_array.slice(bytes, offset, width) {
    Ok(value) -> Ok(value)
    Error(_) -> Error(error.ArchiveInvalid(message: "ZIP slice out of bounds"))
  }
}

fn bytes_to_string(bytes: BitArray) -> Result(String, error.ArchiveError) {
  case bit_array.to_string(bytes) {
    Ok(value) -> Ok(value)
    Error(_) ->
      Error(error.ArchiveInvalid(message: "non-UTF-8 ZIP name (set EFS flag)"))
  }
}

// Decide whether to set the Language Encoding Flag (gp flag bit 11)
// on an entry whose filename serialises to the given bytes.  ASCII
// bytes (< 0x80) are identical in UTF-8 and CP437, so the flag is
// redundant for pure-ASCII names and we leave it clear.  Any byte
// ≥ 0x80 indicates a UTF-8 multibyte sequence and we set the flag
// so spec-conformant decoders treat the name as UTF-8 instead of
// CP437.
fn name_needs_utf8_flag(name_bytes: BitArray) -> Bool {
  case name_bytes {
    <<b, rest:bytes>> ->
      case b >= 0x80 {
        True -> True
        False -> name_needs_utf8_flag(rest)
      }
    _ -> False
  }
}

fn le16(value: Int) -> BitArray {
  <<value:size(16)-little>>
}

fn le32(value: Int) -> BitArray {
  <<value:size(32)-little>>
}

fn read_le16_at(bytes: BitArray, offset: Int) -> Result(Int, error.ArchiveError) {
  case bit_array.slice(bytes, offset, 2) {
    Ok(<<value:size(16)-little>>) -> Ok(value)
    _ -> Error(error.ArchiveInvalid(message: "short read for 16-bit value"))
  }
}

fn read_le32_at(bytes: BitArray, offset: Int) -> Result(Int, error.ArchiveError) {
  case bit_array.slice(bytes, offset, 4) {
    Ok(<<value:size(32)-little>>) -> Ok(value)
    _ -> Error(error.ArchiveInvalid(message: "short read for 32-bit value"))
  }
}

fn read_le32(bytes: BitArray) -> Result(Int, error.ArchiveError) {
  case bytes {
    <<value:size(32)-little>> -> Ok(value)
    _ -> Error(error.ArchiveInvalid(message: "short read for 32-bit value"))
  }
}

fn read_le64_at(bytes: BitArray, offset: Int) -> Result(Int, error.ArchiveError) {
  case bit_array.slice(bytes, offset, 8) {
    Ok(<<value:size(64)-little>>) -> Ok(value)
    _ -> Error(error.ArchiveInvalid(message: "short read for 64-bit value"))
  }
}

fn le64(value: Int) -> BitArray {
  <<value:size(64)-little>>
}

/// Parse the Zip64 extended-information extra field (header_id 0x0001)
/// out of a packed extra-field block.  Only the slots that hit the
/// 0xFFFFFFFF sentinel in the surrounding central-directory or local
/// file header have 8-byte values present in the extra-field body,
/// and they appear in a fixed order (uncomp_size, comp_size,
/// local_offset, disk_start).  The decoder walks the extra-field
/// chain and picks the first record with `header_id = 0x0001`.
fn parse_zip64_extra(
  extra: BitArray,
  uncomp_at_sentinel: Bool,
  comp_at_sentinel: Bool,
  offset_at_sentinel: Bool,
) -> Result(#(Option(Int), Option(Int), Option(Int)), error.ArchiveError) {
  case find_extra_field(extra, zip64_extra_id) {
    Ok(payload) ->
      decode_zip64_extra_payload(
        payload,
        uncomp_at_sentinel,
        comp_at_sentinel,
        offset_at_sentinel,
      )
    _ -> Ok(#(None, None, None))
  }
}

fn find_extra_field(extra: BitArray, want_id: Int) -> Result(BitArray, Nil) {
  case extra {
    <<id:size(16)-little, size:size(16)-little, rest:bytes>> ->
      step_extra_field(rest, size, id, want_id)
    _ -> Error(Nil)
  }
}

fn step_extra_field(
  rest: BitArray,
  size: Int,
  id: Int,
  want_id: Int,
) -> Result(BitArray, Nil) {
  use body <- result.try(case bit_array.slice(rest, 0, size) {
    Ok(b) -> Ok(b)
    _ -> Error(Nil)
  })
  case id == want_id {
    True -> Ok(body)
    False ->
      case bit_array.slice(rest, size, bit_array.byte_size(rest) - size) {
        Ok(after) -> find_extra_field(after, want_id)
        _ -> Error(Nil)
      }
  }
}

fn decode_zip64_extra_payload(
  payload: BitArray,
  uncomp_at_sentinel: Bool,
  comp_at_sentinel: Bool,
  offset_at_sentinel: Bool,
) -> Result(#(Option(Int), Option(Int), Option(Int)), error.ArchiveError) {
  use #(uncomp, payload) <- result.try(maybe_read_le64(
    payload,
    uncomp_at_sentinel,
  ))
  use #(comp, payload) <- result.try(maybe_read_le64(payload, comp_at_sentinel))
  use #(offset, _payload) <- result.try(maybe_read_le64(
    payload,
    offset_at_sentinel,
  ))
  Ok(#(uncomp, comp, offset))
}

fn maybe_read_le64(
  payload: BitArray,
  needed: Bool,
) -> Result(#(Option(Int), BitArray), error.ArchiveError) {
  case needed {
    False -> Ok(#(None, payload))
    True ->
      case payload {
        <<value:size(64)-little, rest:bytes>> -> Ok(#(Some(value), rest))
        _ -> Error(error.ArchiveInvalid(message: "Zip64 extra field truncated"))
      }
  }
}
