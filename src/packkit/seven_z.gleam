//// 7z archive — minimal pure-Gleam reader.
////
//// The reader handles the common case produced by `7z a` on a small
//// payload: a single packed stream wrapped in a single folder that
//// uses one coder.  Recognised single-coder ids:
////   - LZMA2 (`0x21`)
////   - raw LZMA (`0x03 0x01 0x01`)
////   - Copy (`0x00`) — identity passthrough
////   - Deflate (`0x04 0x01 0x08`) — raw DEFLATE, delegated to packkit/deflate
////   - BZip2 (`0x04 0x02 0x02`) — full BZh stream, delegated to packkit/bzip2
//// Multiple files packed into that folder are supported when the
//// archive carries a `SubStreamsInfo` block — the parser reads the
//// per-substream sizes from `kSize` (0x09), derives the final size
//// from the folder's total, and splits the decoded stream
//// accordingly.  Multi-coder folders, BCJ filters, multiple folders,
//// encryption, and most encoded-header variants are intentionally
//// rejected with typed `ArchiveNotImplemented` errors so the reader
//// is easy to extend incrementally.  The encoder is unaffected —
//// it still emits a single LZMA-coded folder regardless of which
//// coders the decoder accepts.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import packkit/archive as archives
import packkit/bzip2
import packkit/checksum
import packkit/deflate
import packkit/entry
import packkit/error
import packkit/internal/bcj
import packkit/internal/lzma
import packkit/limit

const signature_size: Int = 32

const lzma2_coder_id: Int = 0x21

const lzma_coder_id_high: Int = 0x03

const lzma_coder_id_mid: Int = 0x01

const lzma_coder_id_low: Int = 0x01

const copy_coder_id: Int = 0x00

const delta_coder_id: Int = 0x03

// BCJ family coder ids (all 4 bytes, sharing the `0x03 0x03 0xNN
// 0xMM` prefix that p7zip's source uses to namespace branch / call
// converters).  The variant byte combinations come from
// `CPP/7zip/Archive/7z/7zHandler.h` in p7zip: x86 = 03_03_01_03,
// PPC = 03_03_02_05, IA-64 = 03_03_04_01, ARM = 03_03_05_01,
// ARM-Thumb = 03_03_07_01, SPARC = 03_03_08_05.  We pattern-match
// the 4-byte ids directly in `classify_coder_id`.
const bcj_prefix_byte_0: Int = 0x03

const bcj_prefix_byte_1: Int = 0x03

const bcj_x86_byte_2: Int = 0x01

const bcj_x86_byte_3: Int = 0x03

const bcj_ppc_byte_2: Int = 0x02

const bcj_ppc_byte_3: Int = 0x05

const bcj_ia64_byte_2: Int = 0x04

const bcj_ia64_byte_3: Int = 0x01

const bcj_arm_byte_2: Int = 0x05

const bcj_arm_byte_3: Int = 0x01

const bcj_armt_byte_2: Int = 0x07

const bcj_armt_byte_3: Int = 0x01

const bcj_sparc_byte_2: Int = 0x08

const bcj_sparc_byte_3: Int = 0x05

const deflate_coder_id_high: Int = 0x04

const deflate_coder_id_mid: Int = 0x01

const deflate_coder_id_low: Int = 0x08

const bzip2_coder_id_high: Int = 0x04

const bzip2_coder_id_mid: Int = 0x02

const bzip2_coder_id_low: Int = 0x02

// NIDs from the 7z specification.
const nid_end: Int = 0x00

const nid_header: Int = 0x01

const nid_archive_properties: Int = 0x02

const nid_additional_streams_info: Int = 0x03

const nid_main_streams_info: Int = 0x04

const nid_files_info: Int = 0x05

const nid_pack_info: Int = 0x06

const nid_unpack_info: Int = 0x07

const nid_sub_streams_info: Int = 0x08

const nid_size: Int = 0x09

const nid_crc: Int = 0x0A

const nid_folder: Int = 0x0B

const nid_coders_unpack_size: Int = 0x0C

const nid_empty_stream: Int = 0x0E

const nid_empty_file: Int = 0x0F

const nid_anti: Int = 0x10

const nid_name: Int = 0x11

const nid_ctime: Int = 0x12

const nid_atime: Int = 0x13

const nid_mtime: Int = 0x14

const nid_win_attributes: Int = 0x15

const nid_comment: Int = 0x16

const nid_encoded_header: Int = 0x17

const nid_start_pos: Int = 0x18

const nid_dummy: Int = 0x19

/// 7z archive format marker.
pub fn format() -> archives.ArchiveFormat {
  archives.seven_z()
}

/// Create an empty 7z archive value.
pub fn new() -> archives.Archive {
  archives.new(format: format())
}

/// Coder selection for the single-folder 7z encoder.  Mirrors the
/// `7z a -m0=<method>` CLI option: every entry's body is concatenated,
/// then the whole buffer is fed through the chosen coder and emitted
/// as one folder.  The decoder side accepts the same set plus extra
/// coder ids it doesn't yet have an encoder for (LZMA2, BCJ family,
/// Delta).
pub opaque type Method {
  MethodLzma
  MethodCopy
  MethodDeflate
  MethodBzip2
}

/// Default `Method`: raw LZMA1 with the historical `7z a` defaults
/// (lc=3 / lp=0 / pb=2, 64 KiB dictionary).  Equivalent to passing
/// `seven_z.lzma()` to `encode_with_method`.
pub fn lzma() -> Method {
  MethodLzma
}

/// `Method` constructor: identity (no compression).  Equivalent to
/// `7z a -m0=Copy`.  The packed bytes stored in the folder are the
/// concatenated entry bodies verbatim.
pub fn copy() -> Method {
  MethodCopy
}

/// `Method` constructor: raw DEFLATE (no zlib / gzip wrapper).  The
/// concatenated entry bodies go through `packkit/deflate.encode`.
/// Equivalent to `7z a -m0=Deflate`.
pub fn deflate() -> Method {
  MethodDeflate
}

/// `Method` constructor: full bzip2 stream (with `BZh` magic and CRCs).
/// The concatenated entry bodies go through `packkit/bzip2.encode`.
/// Equivalent to `7z a -m0=BZip2`.
pub fn bzip2() -> Method {
  MethodBzip2
}

/// Encode a logical archive to a 7z byte stream.
///
/// The encoder produces a single-folder, single-coder archive that
/// uses a raw LZMA1 coder for the packed stream.  All file bodies are
/// concatenated into one logical substream which is then fed to
/// `packkit/internal/lzma.encode_literal_only`; if the archive holds
/// more than one entry, the per-substream sizes are emitted via
/// `SubStreamsInfo` so the standard decoder can split the decompressed
/// bytes back into individual entries.
///
/// Restrictions: only `File` entries are accepted (no directories,
/// symlinks, or hardlinks — these would require the `EmptyStream` /
/// `Attribute` / `WinAttributes` blocks the reader does not yet
/// validate).  Empty archives are rejected because the 7z format
/// requires `MainStreamsInfo` to be present once a `Header` block
/// exists.
pub fn encode(
  archive archive_value: archives.Archive,
) -> Result(BitArray, error.ArchiveError) {
  encode_with_method(archive: archive_value, method: lzma())
}

/// Same as `encode/1` but lets the caller pick the coder.  All four
/// methods produce a single-folder, single-coder archive — Copy is
/// just the raw bytes; Deflate / BZip2 / LZMA dispatch to the
/// corresponding packkit codec.  Cross-method round-trips work
/// because the decoder accepts each of these coder ids.
pub fn encode_with_method(
  archive archive_value: archives.Archive,
  method method: Method,
) -> Result(BitArray, error.ArchiveError) {
  let entries = archives.entries(archive_value)
  case entries {
    [] ->
      Error(error.ArchiveEntryRejected(
        path: "<archive>",
        reason: "7z encoder requires at least one entry",
      ))
    _ -> encode_entries(entries, method)
  }
}

fn encode_entries(
  entries: List(entry.Entry),
  method: Method,
) -> Result(BitArray, error.ArchiveError) {
  use _ <- result.try(validate_entries_for_encode(entries))

  let bodies = list.map(entries, entry.body)
  let names = list.map(entries, fn(e) { entry.to_string(entry.path(e)) })
  let unpack_sizes = list.map(bodies, bit_array.byte_size)
  let total_unpack = sum_list(unpack_sizes, 0)
  let concatenated = bit_array.concat(bodies)

  use #(compressed, coder_def) <- result.try(encode_via_method(
    concatenated,
    method,
  ))
  let pack_size = bit_array.byte_size(compressed)

  // -- PackInfo ----------------------------------------------------
  let pack_info_body =
    bit_array.concat([
      write_varint(0),
      write_varint(1),
      <<nid_size>>,
      write_varint(pack_size),
      <<nid_end>>,
    ])
  let pack_info = <<nid_pack_info, pack_info_body:bits>>

  // -- CodersInfo / UnPackInfo -------------------------------------
  let folder_def =
    bit_array.concat([
      // num_folders = 1, external = inline.
      write_varint(1),
      <<0x00>>,
      // num_coders = 1.
      write_varint(1),
      // Coder definition (flags + id + optional attrs); per-method.
      coder_def,
    ])
  let unpack_info_body =
    bit_array.concat([
      <<nid_folder>>,
      folder_def,
      <<nid_coders_unpack_size>>,
      write_varint(total_unpack),
      <<nid_end>>,
    ])
  let unpack_info = <<nid_unpack_info, unpack_info_body:bits>>

  // -- SubStreamsInfo (only when more than one file) ---------------
  let sub_streams_info = case entries {
    [_] -> <<>>
    _ -> build_sub_streams_info(unpack_sizes)
  }

  // -- MainStreamsInfo ---------------------------------------------
  let main_streams =
    bit_array.concat([
      <<nid_main_streams_info>>,
      pack_info,
      unpack_info,
      sub_streams_info,
      <<nid_end>>,
    ])

  // -- FilesInfo ---------------------------------------------------
  use names_block <- result.try(encode_names_block(names))
  let num_files = list.length(entries)
  let mtimes_unix =
    list.map(entries, fn(e) { entry.modified_at_unix(entry.metadata(e)) })
  // Only emit the Mtime block when at least one entry carries a
  // recorded mtime (> 0).  An archive of "no mtime" entries stays
  // bit-for-bit identical to the pre-mtime encoder output, so a
  // round-trip without any `with_modified_at` call decodes back to
  // `modified_at_unix = 0` on every entry.
  let any_mtime_set = list.any(mtimes_unix, fn(m) { m > 0 })
  let mtime_block = case any_mtime_set {
    True -> build_mtime_block(mtimes_unix)
    False -> <<>>
  }
  let files_info =
    bit_array.concat([
      <<nid_files_info>>,
      write_varint(num_files),
      <<nid_name>>,
      write_varint(bit_array.byte_size(names_block)),
      names_block,
      mtime_block,
      <<nid_end>>,
    ])

  // -- Header block ------------------------------------------------
  let next_header =
    bit_array.concat([
      <<nid_header>>,
      main_streams,
      files_info,
      <<nid_end>>,
    ])

  let next_header_size = bit_array.byte_size(next_header)
  let next_header_crc = checksum.crc32(next_header)
  let next_header_offset = pack_size

  // -- Signature header --------------------------------------------
  let post_signature_20 = <<
    next_header_offset:little-size(64),
    next_header_size:little-size(64),
    next_header_crc:little-size(32),
  >>
  let start_crc = checksum.crc32(post_signature_20)
  let signature_header =
    bit_array.concat([
      <<0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C>>,
      <<0x00, 0x04>>,
      <<start_crc:little-size(32)>>,
      post_signature_20,
    ])

  Ok(bit_array.concat([signature_header, compressed, next_header]))
}

fn validate_entries_for_encode(
  entries: List(entry.Entry),
) -> Result(Nil, error.ArchiveError) {
  case entries {
    [] -> Ok(Nil)
    [head, ..rest] ->
      case entry.kind(head) {
        entry.File -> validate_entries_for_encode(rest)
        _ ->
          Error(error.ArchiveEntryRejected(
            path: entry.to_string(entry.path(head)),
            reason: "7z encoder currently supports File entries only",
          ))
      }
  }
}

// Encode the concatenated entry bodies via the requested method and
// emit the matching coder definition (flags + id + optional attrs).
// Each branch returns `#(packed_bytes, coder_definition_bytes)`; the
// surrounding encoder splices the coder definition into the folder
// header and the packed bytes into the pack region.  Codec failures
// (deflate / bzip2) propagate as `ArchiveError` via `codec_to_archive`.
fn encode_via_method(
  bytes: BitArray,
  method: Method,
) -> Result(#(BitArray, BitArray), error.ArchiveError) {
  case method {
    MethodLzma -> {
      // LZMA1 with the historical `7z a` defaults (`lc=3 / lp=0 /
      // pb=2`, 64 KiB dictionary).  Coder flags 0x23 = id_size=3 +
      // attrs present.
      let props = lzma.Properties(lc: 3, lp: 0, pb: 2)
      let compressed = lzma.encode_with_lz77(bytes: bytes, props: props)
      let prop_byte = lzma.properties_to_byte(props)
      let dict_size_bytes = <<0x10000:little-size(32)>>
      let coder_def = <<
        0x23,
        lzma_coder_id_high,
        lzma_coder_id_mid,
        lzma_coder_id_low,
        write_varint(5):bits,
        prop_byte,
        dict_size_bytes:bits,
      >>
      Ok(#(compressed, coder_def))
    }
    MethodCopy -> {
      // Identity coder: packed bytes ARE the unpack bytes.  Coder
      // flags 0x01 = id_size=1, no attrs.
      let coder_def = <<0x01, copy_coder_id>>
      Ok(#(bytes, coder_def))
    }
    MethodDeflate -> {
      // Raw DEFLATE (no zlib / gzip wrapper).  Coder id is the 3-byte
      // `04 01 08`; flags 0x03 = id_size=3, no attrs.
      use compressed <- result.try(
        deflate.encode(bytes: bytes) |> result.map_error(codec_to_archive),
      )
      let coder_def = <<
        0x03,
        deflate_coder_id_high,
        deflate_coder_id_mid,
        deflate_coder_id_low,
      >>
      Ok(#(compressed, coder_def))
    }
    MethodBzip2 -> {
      // Full `BZh` bzip2 stream (with magic + CRCs).  Coder id is
      // the 3-byte `04 02 02`; flags 0x03 = id_size=3, no attrs.
      use compressed <- result.try(
        bzip2.encode(bytes: bytes) |> result.map_error(codec_to_archive),
      )
      let coder_def = <<
        0x03,
        bzip2_coder_id_high,
        bzip2_coder_id_mid,
        bzip2_coder_id_low,
      >>
      Ok(#(compressed, coder_def))
    }
  }
}

fn build_sub_streams_info(unpack_sizes: List(Int)) -> BitArray {
  // 7z encodes the first N-1 substream sizes explicitly; the final
  // size is implied (folder_total - sum_of_explicit).  Skip the last
  // entry when emitting.
  let explicit_sizes = drop_last(unpack_sizes, [])
  let size_block =
    list.fold(explicit_sizes, <<>>, fn(acc, n) {
      bit_array.concat([acc, write_varint(n)])
    })
  let num_files = list.length(unpack_sizes)
  bit_array.concat([
    <<nid_sub_streams_info>>,
    // kNumUnPackStream
    <<0x0D>>,
    write_varint(num_files),
    <<nid_size>>,
    size_block,
    <<nid_end>>,
  ])
}

fn drop_last(values: List(a), acc: List(a)) -> List(a) {
  case values {
    [] -> list.reverse(acc)
    [_] -> list.reverse(acc)
    [head, ..rest] -> drop_last(rest, [head, ..acc])
  }
}

// Build a serialised FilesInfo Mtime block (NID 0x14) for the given
// per-entry Unix mtimes.  Entries with mtime <= 0 are marked
// "undefined" via the bitmap; entries with mtime > 0 contribute one
// 8-byte FILETIME LE.  When every entry is defined the bitmap is
// omitted and the `all_defined` flag is set to 1, matching the
// canonical form `7z a -mtm=on` emits.
fn build_mtime_block(mtimes_unix: List(Int)) -> BitArray {
  let defined_flags = list.map(mtimes_unix, fn(m) { m > 0 })
  let all_defined = list.all(defined_flags, fn(b) { b })
  let num_files = list.length(mtimes_unix)
  let filetime_payload =
    list.fold(mtimes_unix, <<>>, fn(acc, m) {
      case m > 0 {
        True -> {
          let ft = unix_to_filetime(m)
          bit_array.concat([acc, <<ft:little-size(64)>>])
        }
        False -> acc
      }
    })
  let body = case all_defined {
    True -> bit_array.concat([<<0x01, 0x00>>, filetime_payload])
    False -> {
      let bitmap = pack_bool_bits(defined_flags, num_files)
      bit_array.concat([<<0x00, 0x00>>, bitmap, filetime_payload])
    }
  }
  bit_array.concat([
    <<nid_mtime>>,
    write_varint(bit_array.byte_size(body)),
    body,
  ])
}

// Pack a list of `count` booleans into ceil(count / 8) bytes,
// MSB-first within each byte, padding the trailing byte with 0 bits.
// Matches the 7z bitmap layout used by both EmptyStream/EmptyFile and
// the Mtime defined-flags block.
fn pack_bool_bits(bits: List(Bool), count: Int) -> BitArray {
  pack_bool_bits_loop(bits, count, 0, 0, <<>>)
}

fn pack_bool_bits_loop(
  bits: List(Bool),
  remaining: Int,
  bit_index: Int,
  current_byte: Int,
  acc: BitArray,
) -> BitArray {
  case remaining {
    0 ->
      case bit_index {
        0 -> acc
        _ -> bit_array.concat([acc, <<current_byte>>])
      }
    _ -> {
      let #(head, tail) = case bits {
        [b, ..rest] -> #(b, rest)
        [] -> #(False, [])
      }
      let bit_value = case head {
        True -> 1
        False -> 0
      }
      let updated_byte =
        int.bitwise_or(
          current_byte,
          int.bitwise_shift_left(bit_value, 7 - bit_index),
        )
      case bit_index == 7 {
        True ->
          pack_bool_bits_loop(
            tail,
            remaining - 1,
            0,
            0,
            bit_array.concat([acc, <<updated_byte>>]),
          )
        False ->
          pack_bool_bits_loop(
            tail,
            remaining - 1,
            bit_index + 1,
            updated_byte,
            acc,
          )
      }
    }
  }
}

fn encode_names_block(
  names: List(String),
) -> Result(BitArray, error.ArchiveError) {
  // External-flag byte (0 = inline) followed by NUL-terminated
  // UTF-16 LE strings, one per file.
  use bodies <- result.try(encode_names_loop(names, <<>>))
  Ok(<<0x00, bodies:bits>>)
}

fn encode_names_loop(
  names: List(String),
  acc: BitArray,
) -> Result(BitArray, error.ArchiveError) {
  case names {
    [] -> Ok(acc)
    [name, ..rest] -> {
      use encoded <- result.try(encode_utf16_le_name(name))
      encode_names_loop(rest, bit_array.concat([acc, encoded]))
    }
  }
}

fn encode_utf16_le_name(name: String) -> Result(BitArray, error.ArchiveError) {
  let codepoints = string.to_utf_codepoints(name)
  use body <- result.try(encode_utf16_le_codepoints(codepoints, <<>>, name))
  // NUL terminator (two zero bytes for UTF-16 LE).
  Ok(<<body:bits, 0, 0>>)
}

fn encode_utf16_le_codepoints(
  codepoints: List(UtfCodepoint),
  acc: BitArray,
  full_name: String,
) -> Result(BitArray, error.ArchiveError) {
  case codepoints {
    [] -> Ok(acc)
    [cp, ..rest] -> {
      let value = string.utf_codepoint_to_int(cp)
      case value < 0x10000 {
        True -> {
          let low = int.bitwise_and(value, 0xFF)
          let high = int.bitwise_shift_right(value, 8)
          encode_utf16_le_codepoints(rest, <<acc:bits, low, high>>, full_name)
        }
        False ->
          Error(error.ArchiveEntryRejected(
            path: full_name,
            reason: "7z encoder requires BMP-only file names (no UTF-16 surrogate pairs yet)",
          ))
      }
    }
  }
}

/// 7z-style 1..5 byte varint.  The first byte's leading 1-bits encode
/// the total length; the trailing bytes carry the lower bytes of the
/// value little-endian.  Cap is 2^35 - 1 which comfortably covers
/// every size field the encoder will produce in practice.
fn write_varint(value: Int) -> BitArray {
  let #(num_bytes, header_top) = case value {
    n if n < 0x80 -> #(1, 0x00)
    n if n < 0x4000 -> #(2, 0x80)
    n if n < 0x200000 -> #(3, 0xC0)
    n if n < 0x10000000 -> #(4, 0xE0)
    _ -> #(5, 0xF0)
  }
  let trailers = num_bytes - 1
  let divisor = int_pow(256, trailers)
  let high_value = value / divisor
  let low_value = value - high_value * divisor
  let first_byte = int.bitwise_or(header_top, high_value)
  let trailer_bytes = encode_le_bytes(low_value, trailers, <<>>)
  <<first_byte, trailer_bytes:bits>>
}

fn encode_le_bytes(value: Int, count: Int, acc: BitArray) -> BitArray {
  case count {
    0 -> acc
    _ -> {
      let byte = value - { value / 256 } * 256
      let shifted = value / 256
      encode_le_bytes(shifted, count - 1, <<acc:bits, byte>>)
    }
  }
}

fn int_pow(base: Int, exp: Int) -> Int {
  case exp {
    0 -> 1
    _ -> base * int_pow(base, exp - 1)
  }
}

/// Decode a 7z byte stream using the default limits.
pub fn decode(
  bytes bytes: BitArray,
) -> Result(archives.Archive, error.ArchiveError) {
  decode_with_limits(bytes: bytes, limits: limit.default())
}

/// Decode a 7z byte stream using explicit limits.  Enforces
/// `max_input_bytes` at entry, `max_output_bytes` against the
/// declared unpack size before invoking the LZMA/LZMA2 decoder,
/// and `max_members` / `max_entry_depth` while materialising the
/// logical entry list.
pub fn decode_with_limits(
  bytes bytes: BitArray,
  limits limits: limit.Limits,
) -> Result(archives.Archive, error.ArchiveError) {
  use <- bool.guard(
    when: bit_array.byte_size(bytes) > limit.max_input_bytes(limits),
    return: Error(error.ArchiveLimitExceeded(
      limit: "max_input_bytes",
      actual: bit_array.byte_size(bytes),
    )),
  )

  use #(next_offset, next_size, _crc) <- result.try(parse_signature_header(
    bytes,
  ))
  use packed_streams <- result.try(slice_required(
    bytes,
    signature_size,
    next_offset,
    "7z packed streams region",
  ))
  use next_header_bytes <- result.try(slice_required(
    bytes,
    signature_size + next_offset,
    next_size,
    "7z next header",
  ))
  use header <- result.try(case next_header_bytes {
    <<n, rest:bytes>> if n == nid_encoded_header ->
      decode_encoded_header(rest, bytes, limits)
    _ -> Ok(next_header_bytes)
  })
  use parsed <- result.try(parse_header(header))
  decode_archive(packed_streams, parsed, limits)
}

// -- encoded next header (NID 0x17) ------------------------------------

fn decode_encoded_header(
  bytes_after_nid: BitArray,
  full_archive: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, error.ArchiveError) {
  // The encoded-header body is a StreamsInfo block describing the
  // packed stream(s) that contain the *actual* next-header bytes.
  // Parse it through the same MainStreamsInfo parser, then decode the
  // packed stream using the declared coder and feed the result back
  // through parse_header.
  use #(streams, _rest) <- result.try(parse_main_streams_info(bytes_after_nid))
  case streams {
    HeaderStreamsNone ->
      Error(error.ArchiveInvalid(
        message: "7z encoded next header has no StreamsInfo",
      ))
    HeaderStreamsParsed(pack_pos, pack_sizes, folders, folder_unpack_sizes, _) -> {
      // The encoded-header path always uses exactly one folder per
      // spec: the next-header bytes are a single LZMA-coded stream.
      // Reject the (unobserved-in-the-wild) multi-folder shape with a
      // typed error rather than silently picking the first folder.
      use <- bool.guard(
        when: list.length(folders) != 1,
        return: Error(error.ArchiveNotImplemented(
          feature: "7z encoded header spread across multiple folders",
        )),
      )
      let assert [folder, ..] = folders
      let assert [unpack_sizes, ..] = folder_unpack_sizes
      let pack_offset = signature_size + pack_pos
      let pack_size = sum_list(pack_sizes, 0)
      use packed <- result.try(slice_required(
        full_archive,
        pack_offset,
        pack_size,
        "7z encoded-header packed bytes",
      ))
      decode_folder(packed, folder, unpack_sizes, limits)
    }
  }
}

// -- signature header ----------------------------------------------------

fn parse_signature_header(
  bytes: BitArray,
) -> Result(#(Int, Int, Int), error.ArchiveError) {
  case bytes {
    <<
      0x37,
      0x7A,
      0xBC,
      0xAF,
      0x27,
      0x1C,
      _major,
      _minor,
      _start_crc:bytes-size(4),
      next_offset_lo:little-unsigned-size(32),
      next_offset_hi:little-unsigned-size(32),
      next_size_lo:little-unsigned-size(32),
      next_size_hi:little-unsigned-size(32),
      next_crc:little-unsigned-size(32),
      _:bytes,
    >> -> {
      use <- bool.guard(
        when: next_offset_hi != 0 || next_size_hi != 0,
        return: Error(error.ArchiveNotImplemented(
          feature: "7z next header above 2^32 bytes",
        )),
      )
      Ok(#(next_offset_lo, next_size_lo, next_crc))
    }
    _ -> Error(error.ArchiveInvalid(message: "invalid 7z signature header"))
  }
}

// -- parsed header model ------------------------------------------------

type ParsedHeader {
  ParsedHeader(
    pack_pos: Int,
    pack_sizes: List(Int),
    /// One `ParsedFolder` per `Folder` definition in the 7z header.
    /// Solid-mode archives (the `7z a` default) have exactly one folder
    /// containing every member; non-solid archives (`7z a -ms=off`)
    /// have one folder per member.  The folder list and the pack-stream
    /// list always have the same length when each folder declares a
    /// single packed input (which is the only shape packkit accepts —
    /// multi-packed-stream folders remain `ArchiveNotImplemented`).
    folders: List(ParsedFolder),
    /// One unpack-size list per folder: `folder_unpack_sizes[i]` holds
    /// the per-coder unpack sizes for folder `i`.  For a 1-coder folder
    /// the list has a single element (the folder's final output size);
    /// for a 2-coder simple chain it has two (intermediate + final).
    folder_unpack_sizes: List(List(Int)),
    substream_sizes: List(Int),
    file_names: List(String),
    empty_streams: List(Bool),
    /// One bit per `empty_streams == True` entry: True means "empty
    /// regular file", False means "directory".  The 7z EmptyFile NID
    /// (0x0F) carries these bits; when the NID is absent the list is
    /// empty and every empty-stream entry is treated as a directory
    /// (the historical default before EmptyFile was honoured).
    empty_files: List(Bool),
    /// One slot per archive member, in declaration order: `Some(unix_seconds)`
    /// when the 7z `Mtime` block (NID 0x14) carried a defined Windows
    /// FILETIME for that member, `None` otherwise.  An empty list means
    /// the archive had no Mtime block at all.  Decoded by
    /// `parse_mtime_block`, applied by `build_archive_entries`.
    mtimes_unix: List(Option(Int)),
  )
}

type ParsedFolder {
  ParsedFolder(coders: List(CoderSpec))
}

type CoderSpec {
  CoderSpec(id: CoderId, properties: BitArray)
}

type CoderId {
  Lzma2
  Lzma
  Copy
  Deflate
  BZip2
  Delta
  BcjX86
  BcjPpc
  BcjIa64
  BcjArm
  BcjArmT
  BcjSparc
}

// -- top-level header parser -------------------------------------------

fn parse_header(header: BitArray) -> Result(ParsedHeader, error.ArchiveError) {
  case header {
    <<head_nid, rest:bytes>> if head_nid == nid_header -> {
      let parser =
        HeaderParser(streams: HeaderStreamsNone, files: HeaderFilesNone)
      use parser <- result.try(parse_header_body(rest, parser))
      finalize_parsed_header(parser)
    }
    _ ->
      Error(error.ArchiveInvalid(
        message: "7z header must start with the Header NID",
      ))
  }
}

type HeaderParser {
  HeaderParser(streams: HeaderStreams, files: HeaderFiles)
}

type HeaderStreams {
  HeaderStreamsNone
  HeaderStreamsParsed(
    pack_pos: Int,
    pack_sizes: List(Int),
    folders: List(ParsedFolder),
    folder_unpack_sizes: List(List(Int)),
    substream_sizes: List(Int),
  )
}

type HeaderFiles {
  HeaderFilesNone
  HeaderFilesParsed(
    names: List(String),
    empty_streams: List(Bool),
    empty_files: List(Bool),
    mtimes_unix: List(Option(Int)),
  )
}

fn parse_header_body(
  bytes: BitArray,
  parser: HeaderParser,
) -> Result(HeaderParser, error.ArchiveError) {
  case bytes {
    <<nid, rest:bytes>> ->
      case nid {
        n if n == nid_end -> Ok(parser)
        n if n == nid_main_streams_info -> {
          use #(streams, rest) <- result.try(parse_main_streams_info(rest))
          parse_header_body(rest, HeaderParser(..parser, streams: streams))
        }
        n if n == nid_files_info -> {
          use #(files, rest) <- result.try(parse_files_info(rest))
          parse_header_body(rest, HeaderParser(..parser, files: files))
        }
        n if n == nid_archive_properties || n == nid_additional_streams_info ->
          Error(error.ArchiveNotImplemented(
            feature: "7z header section NID " <> int.to_string(n),
          ))
        _ ->
          Error(error.ArchiveInvalid(
            message: "unexpected 7z header NID " <> int.to_string(nid),
          ))
      }
    _ -> Ok(parser)
  }
}

fn finalize_parsed_header(
  parser: HeaderParser,
) -> Result(ParsedHeader, error.ArchiveError) {
  case parser.streams, parser.files {
    HeaderStreamsParsed(pack_pos, pack_sizes, folders, folder_unpack_sizes, sub),
      HeaderFilesParsed(names, empty_streams, empty_files, mtimes_unix)
    ->
      Ok(ParsedHeader(
        pack_pos: pack_pos,
        pack_sizes: pack_sizes,
        folders: folders,
        folder_unpack_sizes: folder_unpack_sizes,
        substream_sizes: sub,
        file_names: names,
        empty_streams: empty_streams,
        empty_files: empty_files,
        mtimes_unix: mtimes_unix,
      ))
    HeaderStreamsParsed(pack_pos, pack_sizes, folders, folder_unpack_sizes, sub),
      HeaderFilesNone
    ->
      Ok(
        ParsedHeader(
          pack_pos: pack_pos,
          pack_sizes: pack_sizes,
          folders: folders,
          folder_unpack_sizes: folder_unpack_sizes,
          substream_sizes: sub,
          file_names: [],
          empty_streams: [],
          empty_files: [],
          mtimes_unix: [],
        ),
      )
    _, _ ->
      Error(error.ArchiveInvalid(message: "7z header missing MainStreamsInfo"))
  }
}

// -- MainStreamsInfo ---------------------------------------------------

fn parse_main_streams_info(
  bytes: BitArray,
) -> Result(#(HeaderStreams, BitArray), error.ArchiveError) {
  let state =
    StreamsParser(
      pack_pos: 0,
      pack_sizes: [],
      folders: [],
      folder_unpack_sizes: [],
      substream_sizes: [],
      have_pack: False,
      have_unpack: False,
    )
  parse_streams_loop(bytes, state)
}

type StreamsParser {
  StreamsParser(
    pack_pos: Int,
    pack_sizes: List(Int),
    folders: List(ParsedFolder),
    folder_unpack_sizes: List(List(Int)),
    substream_sizes: List(Int),
    have_pack: Bool,
    have_unpack: Bool,
  )
}

fn parse_streams_loop(
  bytes: BitArray,
  state: StreamsParser,
) -> Result(#(HeaderStreams, BitArray), error.ArchiveError) {
  case bytes {
    <<nid, rest:bytes>> ->
      case nid {
        n if n == nid_end ->
          case state.folders {
            [] ->
              Error(error.ArchiveInvalid(
                message: "7z MainStreamsInfo missing UnPackInfo",
              ))
            _ ->
              Ok(#(
                HeaderStreamsParsed(
                  pack_pos: state.pack_pos,
                  pack_sizes: state.pack_sizes,
                  folders: state.folders,
                  folder_unpack_sizes: state.folder_unpack_sizes,
                  substream_sizes: state.substream_sizes,
                ),
                rest,
              ))
          }
        n if n == nid_pack_info -> {
          use #(pack_pos, pack_sizes, rest) <- result.try(parse_pack_info(rest))
          parse_streams_loop(
            rest,
            StreamsParser(
              ..state,
              pack_pos: pack_pos,
              pack_sizes: pack_sizes,
              have_pack: True,
            ),
          )
        }
        n if n == nid_unpack_info -> {
          use #(folders, folder_unpack_sizes, rest) <- result.try(
            parse_unpack_info(rest),
          )
          parse_streams_loop(
            rest,
            StreamsParser(
              ..state,
              folders: folders,
              folder_unpack_sizes: folder_unpack_sizes,
              have_unpack: True,
            ),
          )
        }
        n if n == nid_sub_streams_info -> {
          // SubStreamsInfo describes how each folder's decoded bytes
          // are split into per-file substreams.  The per-folder
          // substream counts (and any explicit substream sizes) are
          // derived from the folder-final unpack sizes — for each
          // folder we take the last coder's unpack size, which is the
          // folder's final output and therefore the sum of its
          // substreams.
          let folder_totals = list.map(state.folder_unpack_sizes, last_of_list)
          use #(_per_folder, substream_sizes, rest) <- result.try(
            parse_sub_streams_info(
              rest,
              list.length(state.folders),
              folder_totals,
            ),
          )
          parse_streams_loop(
            rest,
            StreamsParser(..state, substream_sizes: substream_sizes),
          )
        }
        _ ->
          Error(error.ArchiveInvalid(
            message: "unexpected 7z MainStreamsInfo NID " <> int.to_string(nid),
          ))
      }
    _ -> Error(error.ArchiveInvalid(message: "truncated 7z MainStreamsInfo"))
  }
}

// -- PackInfo ----------------------------------------------------------

fn parse_pack_info(
  bytes: BitArray,
) -> Result(#(Int, List(Int), BitArray), error.ArchiveError) {
  use #(pack_pos, rest) <- result.try(read_number(bytes))
  use #(num_pack_streams, rest) <- result.try(read_number(rest))
  parse_pack_info_body(rest, pack_pos, num_pack_streams, [])
}

fn parse_pack_info_body(
  bytes: BitArray,
  pack_pos: Int,
  num_pack_streams: Int,
  sizes: List(Int),
) -> Result(#(Int, List(Int), BitArray), error.ArchiveError) {
  case bytes {
    <<nid, rest:bytes>> ->
      case nid {
        n if n == nid_end -> Ok(#(pack_pos, sizes, rest))
        n if n == nid_size -> {
          use #(read_sizes, rest) <- result.try(read_numbers(
            rest,
            num_pack_streams,
          ))
          parse_pack_info_body(rest, pack_pos, num_pack_streams, read_sizes)
        }
        n if n == nid_crc -> {
          use rest <- result.try(skip_crc_block(rest, num_pack_streams))
          parse_pack_info_body(rest, pack_pos, num_pack_streams, sizes)
        }
        _ ->
          Error(error.ArchiveInvalid(
            message: "unexpected 7z PackInfo NID " <> int.to_string(nid),
          ))
      }
    _ -> Error(error.ArchiveInvalid(message: "truncated 7z PackInfo"))
  }
}

// -- UnPackInfo (CodersInfo) -------------------------------------------

fn parse_unpack_info(
  bytes: BitArray,
) -> Result(
  #(List(ParsedFolder), List(List(Int)), BitArray),
  error.ArchiveError,
) {
  parse_unpack_info_body(bytes, [], [])
}

fn parse_unpack_info_body(
  bytes: BitArray,
  folders: List(ParsedFolder),
  folder_unpack_sizes: List(List(Int)),
) -> Result(
  #(List(ParsedFolder), List(List(Int)), BitArray),
  error.ArchiveError,
) {
  case bytes {
    <<nid, rest:bytes>> ->
      case nid {
        n if n == nid_end ->
          case folders {
            [] ->
              Error(error.ArchiveInvalid(
                message: "7z UnPackInfo missing Folder section",
              ))
            _ -> Ok(#(folders, folder_unpack_sizes, rest))
          }
        n if n == nid_folder -> {
          use #(parsed_folders, rest) <- result.try(parse_folders(rest))
          parse_unpack_info_body(rest, parsed_folders, folder_unpack_sizes)
        }
        n if n == nid_coders_unpack_size -> {
          // One UnPackSize per coder output stream per folder.  Each
          // accepted coder is "simple" (1 in / 1 out), so a folder
          // contributes `list.length(folder.coders)` unpack sizes.
          // The 7z spec lists `Folder` before `CodersUnPackSize`, so
          // `folders` is populated by the time we get here.
          let total_size_count =
            list.fold(folders, 0, fn(acc, f) { acc + list.length(f.coders) })
          use #(flat_sizes, rest) <- result.try(read_numbers(
            rest,
            total_size_count,
          ))
          let grouped = split_unpack_sizes_by_folder(flat_sizes, folders, [])
          parse_unpack_info_body(rest, folders, grouped)
        }
        n if n == nid_crc -> {
          use rest <- result.try(skip_crc_block(rest, list.length(folders)))
          parse_unpack_info_body(rest, folders, folder_unpack_sizes)
        }
        _ ->
          Error(error.ArchiveInvalid(
            message: "unexpected 7z UnPackInfo NID " <> int.to_string(nid),
          ))
      }
    _ -> Error(error.ArchiveInvalid(message: "truncated 7z UnPackInfo"))
  }
}

fn parse_folders(
  bytes: BitArray,
) -> Result(#(List(ParsedFolder), BitArray), error.ArchiveError) {
  use #(num_folders, rest) <- result.try(read_number(bytes))
  use <- bool.guard(
    when: num_folders < 1,
    return: Error(error.ArchiveInvalid(
      message: "7z UnPackInfo declares zero folders",
    )),
  )
  case rest {
    <<external, after_external:bytes>> -> {
      use <- bool.guard(
        when: external != 0,
        return: Error(error.ArchiveNotImplemented(
          feature: "7z external folder definitions",
        )),
      )
      parse_folders_loop(after_external, num_folders, [])
    }
    _ -> Error(error.ArchiveInvalid(message: "truncated 7z folder section"))
  }
}

fn parse_folders_loop(
  bytes: BitArray,
  remaining: Int,
  acc: List(ParsedFolder),
) -> Result(#(List(ParsedFolder), BitArray), error.ArchiveError) {
  case remaining {
    0 -> Ok(#(list.reverse(acc), bytes))
    _ -> {
      use #(folder, rest) <- result.try(parse_one_folder(bytes))
      parse_folders_loop(rest, remaining - 1, [folder, ..acc])
    }
  }
}

// Split a flat per-coder unpack-size list across folders, taking
// `list.length(folder.coders)` from the front for each folder in
// order.  Returns folder-aligned size lists in folder order.
fn split_unpack_sizes_by_folder(
  flat: List(Int),
  folders: List(ParsedFolder),
  acc: List(List(Int)),
) -> List(List(Int)) {
  case folders {
    [] -> list.reverse(acc)
    [folder, ..rest] -> {
      let count = list.length(folder.coders)
      let group = list.take(flat, count)
      let leftover = list.drop(flat, count)
      split_unpack_sizes_by_folder(leftover, rest, [group, ..acc])
    }
  }
}

// Parse a single folder definition: NumCoders varint, N coder defs,
// then (when NumCoders > 1) NumBindPairs = NumOutStreams - 1 bind
// pairs and (when NumPackedStreams > 1) the packed-stream indices.
// packkit supports linear 1- or 2-coder chains only; non-linear and
// 3+-coder shapes are rejected with typed `ArchiveNotImplemented`.
fn parse_one_folder(
  bytes: BitArray,
) -> Result(#(ParsedFolder, BitArray), error.ArchiveError) {
  use #(num_coders, rest) <- result.try(read_number(bytes))
  use <- bool.guard(
    when: num_coders < 1,
    return: Error(error.ArchiveInvalid(
      message: "7z folder declares zero coders",
    )),
  )
  use <- bool.guard(
    when: num_coders > 2,
    return: Error(error.ArchiveNotImplemented(
      feature: "7z folders with " <> int.to_string(num_coders) <> " coders",
    )),
  )
  use #(coders, rest) <- result.try(parse_coders_loop(rest, num_coders, []))
  case num_coders {
    1 -> Ok(#(ParsedFolder(coders: coders), rest))
    _ -> {
      // 2-coder simple chain: exactly 1 bind pair, in_idx = 1, out_idx = 0
      // means "coder 1's input is wired from coder 0's output", i.e.
      // packed bytes feed coder 0, coder 1's output is the folder
      // output.  Any other indexing is non-linear (BCJ2 etc) and
      // unsupported.  NumPackedStreams = NumInStreams - NumBindPairs
      // = 2 - 1 = 1, so the spec omits the explicit packed-stream
      // index list — we don't consume anything for it.
      use #(in_idx, after_in) <- result.try(read_number(rest))
      use #(out_idx, after_out) <- result.try(read_number(after_in))
      use <- bool.guard(
        when: in_idx != 1 || out_idx != 0,
        return: Error(error.ArchiveNotImplemented(
          feature: "7z non-linear 2-coder folder topology (bind in="
          <> int.to_string(in_idx)
          <> " out="
          <> int.to_string(out_idx)
          <> ")",
        )),
      )
      Ok(#(ParsedFolder(coders: coders), after_out))
    }
  }
}

fn parse_coders_loop(
  bytes: BitArray,
  remaining: Int,
  acc: List(CoderSpec),
) -> Result(#(List(CoderSpec), BitArray), error.ArchiveError) {
  case remaining {
    0 -> Ok(#(list.reverse(acc), bytes))
    _ -> {
      use #(coder, rest) <- result.try(parse_one_coder(bytes))
      parse_coders_loop(rest, remaining - 1, [coder, ..acc])
    }
  }
}

fn parse_one_coder(
  bytes: BitArray,
) -> Result(#(CoderSpec, BitArray), error.ArchiveError) {
  case bytes {
    <<flags, after_flags:bytes>> -> {
      let id_size = int.bitwise_and(flags, 0x0F)
      let is_complex = int.bitwise_and(flags, 0x10) != 0
      let has_attrs = int.bitwise_and(flags, 0x20) != 0
      use <- bool.guard(
        when: is_complex,
        return: Error(error.ArchiveNotImplemented(
          feature: "7z complex coders (multiple streams)",
        )),
      )
      use coder_id_bytes <- result.try(slice_required(
        after_flags,
        0,
        id_size,
        "7z coder id",
      ))
      let assert Ok(after_coder_id) =
        bit_array.slice(
          after_flags,
          id_size,
          bit_array.byte_size(after_flags) - id_size,
        )
      use coder_id <- result.try(classify_coder_id(coder_id_bytes))
      case has_attrs {
        False ->
          Ok(#(CoderSpec(id: coder_id, properties: <<>>), after_coder_id))
        True -> {
          use #(attrs_size, after_attrs_size) <- result.try(read_number(
            after_coder_id,
          ))
          use attrs <- result.try(slice_required(
            after_attrs_size,
            0,
            attrs_size,
            "7z coder attributes",
          ))
          let assert Ok(after_attrs) =
            bit_array.slice(
              after_attrs_size,
              attrs_size,
              bit_array.byte_size(after_attrs_size) - attrs_size,
            )
          Ok(#(CoderSpec(id: coder_id, properties: attrs), after_attrs))
        }
      }
    }
    _ -> Error(error.ArchiveInvalid(message: "truncated 7z coder definition"))
  }
}

fn classify_coder_id(id_bytes: BitArray) -> Result(CoderId, error.ArchiveError) {
  case id_bytes {
    <<b>> if b == copy_coder_id -> Ok(Copy)
    <<b>> if b == lzma2_coder_id -> Ok(Lzma2)
    <<b>> if b == delta_coder_id -> Ok(Delta)
    <<b1, b2, b3>>
      if b1 == lzma_coder_id_high
      && b2 == lzma_coder_id_mid
      && b3 == lzma_coder_id_low
    -> Ok(Lzma)
    <<b1, b2, b3>>
      if b1 == deflate_coder_id_high
      && b2 == deflate_coder_id_mid
      && b3 == deflate_coder_id_low
    -> Ok(Deflate)
    <<b1, b2, b3>>
      if b1 == bzip2_coder_id_high
      && b2 == bzip2_coder_id_mid
      && b3 == bzip2_coder_id_low
    -> Ok(BZip2)
    <<b1, b2, b3, b4>> if b1 == bcj_prefix_byte_0 && b2 == bcj_prefix_byte_1 ->
      case b3, b4 {
        v3, v4 if v3 == bcj_x86_byte_2 && v4 == bcj_x86_byte_3 -> Ok(BcjX86)
        v3, v4 if v3 == bcj_ppc_byte_2 && v4 == bcj_ppc_byte_3 -> Ok(BcjPpc)
        v3, v4 if v3 == bcj_ia64_byte_2 && v4 == bcj_ia64_byte_3 -> Ok(BcjIa64)
        v3, v4 if v3 == bcj_arm_byte_2 && v4 == bcj_arm_byte_3 -> Ok(BcjArm)
        v3, v4 if v3 == bcj_armt_byte_2 && v4 == bcj_armt_byte_3 -> Ok(BcjArmT)
        v3, v4 if v3 == bcj_sparc_byte_2 && v4 == bcj_sparc_byte_3 ->
          Ok(BcjSparc)
        _, _ ->
          Error(error.ArchiveNotImplemented(
            feature: "7z coder id " <> describe_bit_array_hex(id_bytes, ""),
          ))
      }
    _ ->
      Error(error.ArchiveNotImplemented(
        feature: "7z coder id " <> describe_bit_array_hex(id_bytes, ""),
      ))
  }
}

fn describe_bit_array_hex(bytes: BitArray, acc: String) -> String {
  case bytes {
    <<b, rest:bytes>> -> describe_bit_array_hex(rest, acc <> int.to_base16(b))
    _ -> acc
  }
}

// -- FilesInfo ---------------------------------------------------------

fn parse_files_info(
  bytes: BitArray,
) -> Result(#(HeaderFiles, BitArray), error.ArchiveError) {
  use #(num_files, rest) <- result.try(read_number(bytes))
  parse_files_loop(rest, num_files, [], [], [], [])
}

fn parse_files_loop(
  bytes: BitArray,
  num_files: Int,
  names: List(String),
  empty_streams: List(Bool),
  empty_files: List(Bool),
  mtimes_unix: List(Option(Int)),
) -> Result(#(HeaderFiles, BitArray), error.ArchiveError) {
  case bytes {
    <<nid, rest:bytes>> ->
      case nid {
        n if n == nid_end ->
          Ok(#(
            HeaderFilesParsed(
              names: case names {
                [] -> dummy_names(num_files)
                ns -> ns
              },
              empty_streams: case empty_streams {
                [] -> list.repeat(False, num_files)
                es -> es
              },
              empty_files: empty_files,
              mtimes_unix: mtimes_unix,
            ),
            rest,
          ))
        n if n == nid_name -> {
          use #(size, after_size) <- result.try(read_number(rest))
          use payload <- result.try(slice_required(
            after_size,
            0,
            size,
            "7z file names payload",
          ))
          let assert Ok(after_payload) =
            bit_array.slice(
              after_size,
              size,
              bit_array.byte_size(after_size) - size,
            )
          use parsed_names <- result.try(parse_name_block(payload, num_files))
          parse_files_loop(
            after_payload,
            num_files,
            parsed_names,
            empty_streams,
            empty_files,
            mtimes_unix,
          )
        }
        n if n == nid_empty_stream -> {
          use #(size, after_size) <- result.try(read_number(rest))
          use payload <- result.try(slice_required(
            after_size,
            0,
            size,
            "7z empty-stream payload",
          ))
          let assert Ok(after_payload) =
            bit_array.slice(
              after_size,
              size,
              bit_array.byte_size(after_size) - size,
            )
          let flags = bit_array_to_bool_list(payload, num_files, [])
          parse_files_loop(
            after_payload,
            num_files,
            names,
            flags,
            empty_files,
            mtimes_unix,
          )
        }
        n if n == nid_empty_file -> {
          // EmptyFile's bit list has one bit per EmptyStream-flagged
          // entry (i.e. per True value already collected into
          // `empty_streams`).  Bit=1 means "empty regular file";
          // bit=0 means "directory".  The payload itself is
          // ceil(count/8) bytes when count > 0.  Per 7z spec the
          // EmptyStream block always precedes EmptyFile, so
          // `empty_streams` is populated by this point.
          use #(size, after_size) <- result.try(read_number(rest))
          use payload <- result.try(slice_required(
            after_size,
            0,
            size,
            "7z empty-file payload",
          ))
          let assert Ok(after_payload) =
            bit_array.slice(
              after_size,
              size,
              bit_array.byte_size(after_size) - size,
            )
          let empty_count = count_true(empty_streams)
          let flags = bit_array_to_bool_list(payload, empty_count, [])
          parse_files_loop(
            after_payload,
            num_files,
            names,
            empty_streams,
            flags,
            mtimes_unix,
          )
        }
        n if n == nid_mtime -> {
          // The mtime block carries one Windows FILETIME per file,
          // with an optional bitmap selecting which entries have the
          // field defined.  Layout:
          //   varint size
          //   1 byte all_defined  (1 = every entry has a FILETIME)
          //   1 byte external     (0 = inline payload follows)
          //   if !all_defined: ceil(num_files / 8) bytes of bits
          //   N × 8 bytes FILETIME LE (N = number of defined entries)
          // packkit only honours the inline form; external (1) means
          // the FILETIMEs live in AdditionalStreamsInfo, which is
          // already rejected at the section level above.
          use #(size, after_size) <- result.try(read_number(rest))
          use payload <- result.try(slice_required(
            after_size,
            0,
            size,
            "7z mtime block payload",
          ))
          let assert Ok(after_payload) =
            bit_array.slice(
              after_size,
              size,
              bit_array.byte_size(after_size) - size,
            )
          use parsed_mtimes <- result.try(parse_mtime_block(payload, num_files))
          parse_files_loop(
            after_payload,
            num_files,
            names,
            empty_streams,
            empty_files,
            parsed_mtimes,
          )
        }
        n
          if n == nid_dummy
          || n == nid_ctime
          || n == nid_atime
          || n == nid_win_attributes
          || n == nid_anti
          || n == nid_start_pos
          || n == nid_comment
        -> {
          use #(size, after_size) <- result.try(read_number(rest))
          let assert Ok(after_payload) =
            bit_array.slice(
              after_size,
              size,
              bit_array.byte_size(after_size) - size,
            )
          parse_files_loop(
            after_payload,
            num_files,
            names,
            empty_streams,
            empty_files,
            mtimes_unix,
          )
        }
        _ ->
          Error(error.ArchiveInvalid(
            message: "unexpected 7z FilesInfo NID " <> int.to_string(nid),
          ))
      }
    _ -> Error(error.ArchiveInvalid(message: "truncated 7z FilesInfo"))
  }
}

fn count_true(bits: List(Bool)) -> Int {
  case bits {
    [] -> 0
    [True, ..rest] -> 1 + count_true(rest)
    [False, ..rest] -> count_true(rest)
  }
}

// -- mtime block (NID 0x14) ------------------------------------------
//
// Windows FILETIME counts 100-nanosecond intervals since the Windows
// epoch (1601-01-01 00:00:00 UTC).  Unix time counts seconds since
// the Unix epoch (1970-01-01 00:00:00 UTC), which is exactly
// 11_644_473_600 seconds after the Windows epoch.  Bridging the two
// is therefore:
//   FILETIME = (UnixSeconds + 11_644_473_600) × 10_000_000
//   UnixSeconds = FILETIME / 10_000_000 − 11_644_473_600
// We round toward 0 (integer division), losing the sub-second
// fraction Windows times can carry but the packkit entry model
// cannot represent.

const filetime_epoch_offset_seconds: Int = 11_644_473_600

const filetime_ticks_per_second: Int = 10_000_000

fn unix_to_filetime(unix_seconds: Int) -> Int {
  { unix_seconds + filetime_epoch_offset_seconds } * filetime_ticks_per_second
}

fn filetime_to_unix(filetime: Int) -> Int {
  filetime / filetime_ticks_per_second - filetime_epoch_offset_seconds
}

fn parse_mtime_block(
  payload: BitArray,
  num_files: Int,
) -> Result(List(Option(Int)), error.ArchiveError) {
  case payload {
    <<all_defined, external, after_header:bytes>> -> {
      use <- bool.guard(
        when: external != 0,
        return: Error(error.ArchiveNotImplemented(
          feature: "7z external Mtime block",
        )),
      )
      use defined_flags <- result.try(case all_defined {
        1 -> Ok(list.repeat(True, num_files))
        _ -> read_mtime_defined_flags(after_header, num_files)
      })
      let body_after_flags = case all_defined {
        1 -> after_header
        _ -> {
          let bitmap_size = { num_files + 7 } / 8
          let assert Ok(rest) =
            bit_array.slice(
              after_header,
              bitmap_size,
              bit_array.byte_size(after_header) - bitmap_size,
            )
          rest
        }
      }
      read_mtime_filetimes(body_after_flags, defined_flags, [])
    }
    _ -> Error(error.ArchiveInvalid(message: "truncated 7z mtime block header"))
  }
}

fn read_mtime_defined_flags(
  payload: BitArray,
  num_files: Int,
) -> Result(List(Bool), error.ArchiveError) {
  let bitmap_size = { num_files + 7 } / 8
  use bits <- result.try(slice_required(
    payload,
    0,
    bitmap_size,
    "7z mtime defined bitmap",
  ))
  Ok(bit_array_to_bool_list(bits, num_files, []))
}

fn read_mtime_filetimes(
  payload: BitArray,
  defined_flags: List(Bool),
  acc: List(Option(Int)),
) -> Result(List(Option(Int)), error.ArchiveError) {
  case defined_flags {
    [] -> Ok(list.reverse(acc))
    [False, ..rest] -> read_mtime_filetimes(payload, rest, [option.None, ..acc])
    [True, ..rest] ->
      case payload {
        <<filetime:little-size(64), tail:bytes>> -> {
          let unix_seconds = filetime_to_unix(filetime)
          let safe = case unix_seconds < 0 {
            True -> 0
            False -> unix_seconds
          }
          read_mtime_filetimes(tail, rest, [option.Some(safe), ..acc])
        }
        _ ->
          Error(error.ArchiveInvalid(
            message: "truncated 7z mtime FILETIME entry",
          ))
      }
  }
}

fn dummy_names(count: Int) -> List(String) {
  build_dummy_names(count, 0, [])
}

fn build_dummy_names(count: Int, index: Int, acc: List(String)) -> List(String) {
  case index >= count {
    True -> list.reverse(acc)
    False ->
      build_dummy_names(count, index + 1, [
        "file" <> int.to_string(index),
        ..acc
      ])
  }
}

fn parse_name_block(
  payload: BitArray,
  num_files: Int,
) -> Result(List(String), error.ArchiveError) {
  case payload {
    <<external, rest:bytes>> ->
      case external {
        0 -> decode_utf16_names(rest, num_files, [], [])
        _ ->
          Error(error.ArchiveNotImplemented(
            feature: "7z external file-name table",
          ))
      }
    _ -> Error(error.ArchiveInvalid(message: "truncated 7z file-name section"))
  }
}

fn decode_utf16_names(
  bytes: BitArray,
  remaining: Int,
  current: List(Int),
  acc: List(String),
) -> Result(List(String), error.ArchiveError) {
  case remaining {
    0 -> Ok(list.reverse(acc))
    _ ->
      case bytes {
        <<lo, hi, rest:bytes>> -> {
          let code = int.bitwise_or(int.bitwise_shift_left(hi, 8), lo)
          case code {
            0 -> {
              let assert Ok(name) =
                bit_array.to_string(
                  codepoints_to_bit_array(list.reverse(current), <<>>),
                )
              decode_utf16_names(rest, remaining - 1, [], [name, ..acc])
            }
            _ -> decode_utf16_names(rest, remaining, [code, ..current], acc)
          }
        }
        _ ->
          Error(error.ArchiveInvalid(message: "truncated 7z UTF-16 file name"))
      }
  }
}

fn codepoints_to_bit_array(codes: List(Int), acc: BitArray) -> BitArray {
  case codes {
    [] -> acc
    [code, ..rest] -> codepoints_to_bit_array(rest, encode_utf8_code(code, acc))
  }
}

fn encode_utf8_code(code: Int, acc: BitArray) -> BitArray {
  case code {
    c if c < 0x80 -> <<acc:bits, c>>
    c if c < 0x800 -> {
      let b1 = 0xC0 + int.bitwise_shift_right(c, 6)
      let b2 = 0x80 + int.bitwise_and(c, 0x3F)
      <<acc:bits, b1, b2>>
    }
    c -> {
      let b1 = 0xE0 + int.bitwise_shift_right(c, 12)
      let b2 = 0x80 + int.bitwise_and(int.bitwise_shift_right(c, 6), 0x3F)
      let b3 = 0x80 + int.bitwise_and(c, 0x3F)
      <<acc:bits, b1, b2, b3>>
    }
  }
}

fn bit_array_to_bool_list(
  bytes: BitArray,
  count: Int,
  acc: List(Bool),
) -> List(Bool) {
  case count {
    0 -> list.reverse(acc)
    _ ->
      case bytes {
        <<b, rest:bytes>> -> {
          let bits = unpack_bits(b, 8, [])
          take_bools(bits, rest, count, acc)
        }
        _ -> list.reverse(acc)
      }
  }
}

fn unpack_bits(byte: Int, remaining: Int, acc: List(Bool)) -> List(Bool) {
  case remaining {
    0 -> list.reverse(acc)
    _ -> {
      let bit = int.bitwise_and(int.bitwise_shift_right(byte, remaining - 1), 1)
      unpack_bits(byte, remaining - 1, [bit == 1, ..acc])
    }
  }
}

fn take_bools(
  bits: List(Bool),
  rest_bytes: BitArray,
  count: Int,
  acc: List(Bool),
) -> List(Bool) {
  case bits, count {
    _, 0 -> list.reverse(acc)
    [], _ -> bit_array_to_bool_list(rest_bytes, count, acc)
    [head, ..tail], _ -> take_bools(tail, rest_bytes, count - 1, [head, ..acc])
  }
}

// -- CRC / size helpers ------------------------------------------------

fn skip_crc_block(
  bytes: BitArray,
  count: Int,
) -> Result(BitArray, error.ArchiveError) {
  case bytes {
    <<all_defined, rest:bytes>> ->
      case all_defined {
        1 -> drop_bytes(rest, count * 4, "7z CRC table")
        _ -> {
          let byte_count = { count + 7 } / 8
          use after_flags <- result.try(drop_bytes(
            rest,
            byte_count,
            "7z CRC flag bits",
          ))
          drop_bytes(after_flags, count * 4, "7z CRC values")
        }
      }
    _ -> Error(error.ArchiveInvalid(message: "truncated 7z CRC block"))
  }
}

fn drop_bytes(
  bytes: BitArray,
  count: Int,
  label: String,
) -> Result(BitArray, error.ArchiveError) {
  case bit_array.slice(bytes, count, bit_array.byte_size(bytes) - count) {
    Ok(rest) -> Ok(rest)
    Error(_) -> Error(error.ArchiveInvalid(message: "truncated " <> label))
  }
}

// SubStreamsInfo parser — each NID has a specific data layout, so the
// generic "read NID, read varint, skip" trick used by other generic
// skippers does NOT apply here.
//
// For a single-folder archive (the only shape we currently decode):
//   - `num_substreams_per_folder` is a single-element list giving the
//     file count packed into that folder.
//   - `substream_sizes` lists the per-file unpack sizes.  The 7z spec
//     transmits only the first N-1 explicitly; the last is derived
//     from the folder's total unpack size minus the explicit sum.
//   - When NID 0x0D (kNumUnPackStream) is absent, every folder
//     carries exactly one substream and `substream_sizes` is empty
//     (callers fall back to the folder-level unpack size).
fn parse_sub_streams_info(
  bytes: BitArray,
  num_folders: Int,
  folder_unpack_sizes: List(Int),
) -> Result(#(List(Int), List(Int), BitArray), error.ArchiveError) {
  let initial = SubStreamsAcc(per_folder: [], explicit_sizes: [])
  use #(acc, rest) <- result.try(sub_streams_loop_collect(
    bytes,
    num_folders,
    initial,
  ))
  let per_folder = case acc.per_folder {
    [] -> repeat_one_per_folder(num_folders, [])
    values -> values
  }
  let total_substreams = sum_list(per_folder, 0)
  let sizes =
    derive_substream_sizes(
      per_folder,
      folder_unpack_sizes,
      acc.explicit_sizes,
      [],
    )
  case list.length(sizes) == total_substreams {
    True -> Ok(#(per_folder, sizes, rest))
    False ->
      Error(error.ArchiveInvalid(
        message: "7z SubStreamsInfo: derived substream count mismatch",
      ))
  }
}

type SubStreamsAcc {
  SubStreamsAcc(per_folder: List(Int), explicit_sizes: List(Int))
}

fn sub_streams_loop_collect(
  bytes: BitArray,
  num_folders: Int,
  acc: SubStreamsAcc,
) -> Result(#(SubStreamsAcc, BitArray), error.ArchiveError) {
  case bytes {
    <<nid, rest:bytes>> ->
      case nid {
        n if n == nid_end -> Ok(#(acc, rest))
        0x0D -> {
          // kNumUnPackStream: one varint per folder.
          use #(counts, rest) <- result.try(read_numbers(rest, num_folders))
          sub_streams_loop_collect(
            rest,
            num_folders,
            SubStreamsAcc(..acc, per_folder: counts),
          )
        }
        n if n == nid_size -> {
          // kSize: for each folder, (substream_count - 1) varints.
          // When kNumUnPackStream was absent every folder has exactly
          // one substream and kSize carries no values.
          let per_folder = case acc.per_folder {
            [] -> repeat_one_per_folder(num_folders, [])
            values -> values
          }
          let explicit_count = sum_list(per_folder, 0) - list.length(per_folder)
          let safe_count = case explicit_count > 0 {
            True -> explicit_count
            False -> 0
          }
          use #(sizes, rest) <- result.try(read_numbers(rest, safe_count))
          sub_streams_loop_collect(
            rest,
            num_folders,
            SubStreamsAcc(..acc, explicit_sizes: sizes),
          )
        }
        n if n == nid_crc -> {
          let total = case acc.per_folder {
            [] -> num_folders
            values -> sum_list(values, 0)
          }
          use rest <- result.try(skip_crc_block(rest, total))
          sub_streams_loop_collect(rest, num_folders, acc)
        }
        _ ->
          Error(error.ArchiveInvalid(
            message: "unexpected 7z SubStreamsInfo NID " <> int.to_string(nid),
          ))
      }
    _ -> Error(error.ArchiveInvalid(message: "truncated 7z SubStreamsInfo"))
  }
}

fn repeat_one_per_folder(n: Int, acc: List(Int)) -> List(Int) {
  case n {
    0 -> acc
    _ -> repeat_one_per_folder(n - 1, [1, ..acc])
  }
}

fn derive_substream_sizes(
  per_folder: List(Int),
  folder_unpack_sizes: List(Int),
  remaining_explicit: List(Int),
  acc: List(Int),
) -> List(Int) {
  case per_folder, folder_unpack_sizes {
    [], _ | _, [] -> list.reverse(acc)
    [count, ..rest_counts], [folder_total, ..rest_folder_totals] -> {
      // The first (count - 1) substream sizes are explicit; the last
      // is derived so the folder's total matches.
      let explicit_for_folder = case count {
        0 -> 0
        _ -> count - 1
      }
      let #(explicit, remaining) =
        list_take(remaining_explicit, explicit_for_folder, [])
      let explicit_sum = sum_list(explicit, 0)
      let derived = folder_total - explicit_sum
      let folder_sizes = case count {
        0 -> []
        _ -> list.append(explicit, [derived])
      }
      derive_substream_sizes(
        rest_counts,
        rest_folder_totals,
        remaining,
        list.append(list.reverse(folder_sizes), acc),
      )
    }
  }
}

fn list_take(values: List(a), n: Int, acc: List(a)) -> #(List(a), List(a)) {
  case values, n {
    _, 0 -> #(list.reverse(acc), values)
    [], _ -> #(list.reverse(acc), [])
    [head, ..rest], _ -> list_take(rest, n - 1, [head, ..acc])
  }
}

fn sum_list(values: List(Int), acc: Int) -> Int {
  case values {
    [] -> acc
    [head, ..rest] -> sum_list(rest, acc + head)
  }
}

// -- final extraction --------------------------------------------------

fn decode_archive(
  packed: BitArray,
  parsed: ParsedHeader,
  limits: limit.Limits,
) -> Result(archives.Archive, error.ArchiveError) {
  let _ = parsed.pack_pos

  // The declared unpack sizes live in the header, so we can refuse an
  // oversized payload before the LZMA range coder runs — a malicious
  // archive that advertises a multi-GB unpack size shouldn't be able
  // to make us allocate it just to be rejected at the end.
  use _ <- result.try(enforce_max_output(
    list.flatten(parsed.folder_unpack_sizes),
    limits,
  ))

  // Likewise refuse archives that advertise more members than the
  // caller is willing to materialise — independent of the unpack
  // payload, since the file list lives in the next header.
  let declared_members = list.length(parsed.file_names)
  use <- bool.guard(
    when: declared_members > limit.max_members(limits),
    return: Error(error.ArchiveLimitExceeded(
      limit: "max_members",
      actual: declared_members,
    )),
  )

  // Multi-folder archives ship one packed stream per folder.  Walk
  // both lists in lockstep, slicing the per-folder pack region from
  // the catenated `packed` buffer (the regions are written
  // back-to-back in folder order) and decoding each folder
  // independently.  The decoded outputs are concatenated in folder
  // order so the downstream entry builder sees a single buffer that
  // matches the file order.
  use plain <- result.try(
    decode_all_folders(
      packed,
      parsed.folders,
      parsed.folder_unpack_sizes,
      parsed.pack_sizes,
      limits,
      0,
      [],
    ),
  )
  build_archive_entries(plain, parsed, limits)
}

fn decode_all_folders(
  packed: BitArray,
  folders: List(ParsedFolder),
  folder_unpack_sizes: List(List(Int)),
  pack_sizes: List(Int),
  limits: limit.Limits,
  pack_cursor: Int,
  acc: List(BitArray),
) -> Result(BitArray, error.ArchiveError) {
  case folders, folder_unpack_sizes, pack_sizes {
    [], [], _ -> Ok(bit_array.concat(list.reverse(acc)))
    [folder, ..rest_folders],
      [unpack_sizes, ..rest_unpack],
      [pack_size, ..rest_pack]
    -> {
      use folder_packed <- result.try(slice_required(
        packed,
        pack_cursor,
        pack_size,
        "7z per-folder packed bytes",
      ))
      use folder_plain <- result.try(decode_folder(
        folder_packed,
        folder,
        unpack_sizes,
        limits,
      ))
      decode_all_folders(
        packed,
        rest_folders,
        rest_unpack,
        rest_pack,
        limits,
        pack_cursor + pack_size,
        [folder_plain, ..acc],
      )
    }
    _, _, _ ->
      Error(error.ArchiveInvalid(
        message: "7z folder / unpack-size / pack-size lists are misaligned",
      ))
  }
}

fn enforce_max_output(
  unpack_sizes: List(Int),
  limits: limit.Limits,
) -> Result(Nil, error.ArchiveError) {
  let total = sum_list(unpack_sizes, 0)
  case total > limit.max_output_bytes(limits) {
    True ->
      Error(error.ArchiveLimitExceeded(limit: "max_output_bytes", actual: total))
    False -> Ok(Nil)
  }
}

fn decode_folder(
  packed: BitArray,
  folder: ParsedFolder,
  unpack_sizes: List(Int),
  limits: limit.Limits,
) -> Result(BitArray, error.ArchiveError) {
  case folder.coders {
    [single] -> dispatch_coder(packed, single, unpack_sizes, limits)
    [first, second] -> {
      // 2-coder linear chain: packed bytes feed `first`, its output
      // feeds `second`, and `second`'s output is the folder output.
      // The two CodersUnPackSize entries match that ordering — entry 0
      // = first coder's output size, entry 1 = second coder's output
      // size (= the folder unpack total we use for substream
      // splitting).
      let #(first_unpack, final_unpack) = case unpack_sizes {
        [a, b, ..] -> #(a, b)
        [a] -> #(a, a)
        [] -> #(0, 0)
      }
      use intermediate <- result.try(dispatch_coder(
        packed,
        first,
        [first_unpack],
        limits,
      ))
      dispatch_coder(intermediate, second, [final_unpack], limits)
    }
    _ ->
      Error(error.ArchiveInvalid(
        message: "7z folder has unsupported coder count",
      ))
  }
}

fn dispatch_coder(
  packed: BitArray,
  spec: CoderSpec,
  unpack_sizes: List(Int),
  limits: limit.Limits,
) -> Result(BitArray, error.ArchiveError) {
  case spec.id {
    Lzma2 -> decode_lzma2_payload(packed, spec.properties, unpack_sizes)
    Lzma -> decode_raw_lzma(packed, spec.properties, unpack_sizes)
    Copy -> decode_copy_coder(packed, unpack_sizes)
    Deflate -> decode_deflate_coder(packed, unpack_sizes, limits)
    BZip2 -> decode_bzip2_coder(packed, unpack_sizes, limits)
    Delta -> decode_delta_coder(packed, spec.properties, unpack_sizes)
    BcjX86 -> decode_bcj_coder(packed, unpack_sizes, bcj.x86_decode, "x86")
    BcjPpc ->
      decode_bcj_coder(packed, unpack_sizes, bcj.powerpc_decode, "PowerPC")
    BcjIa64 -> decode_bcj_coder(packed, unpack_sizes, bcj.ia64_decode, "IA-64")
    BcjArm -> decode_bcj_coder(packed, unpack_sizes, bcj.arm_decode, "ARM")
    BcjArmT ->
      decode_bcj_coder(packed, unpack_sizes, bcj.armthumb_decode, "ARM-Thumb")
    BcjSparc ->
      decode_bcj_coder(packed, unpack_sizes, bcj.sparc_decode, "SPARC")
  }
}

// Every BCJ variant takes the same shape: a byte transform parameterised
// by the architecture-specific decoder function, run with `now_pos = 0`
// at every folder boundary (matching xz's per-block reset convention,
// which the p7zip implementation also uses).  The folder's declared
// unpack size is cross-checked afterwards so a corrupted upstream coder
// can't silently feed a short buffer through.
fn decode_bcj_coder(
  packed: BitArray,
  unpack_sizes: List(Int),
  decoder: fn(BitArray, Int) -> BitArray,
  arch_name: String,
) -> Result(BitArray, error.ArchiveError) {
  let target = folder_unpack_total(unpack_sizes)
  let decoded = decoder(packed, 0)
  verify_unpack_size(decoded, target, "BCJ " <> arch_name)
}

// The Delta filter records the byte distance over which to take the
// difference between adjacent samples.  7z stores the distance as a
// single attribute byte that holds `distance - 1`, so values 0..255
// span distances 1..256.  Decoding sums each input byte with the
// byte `distance` positions earlier in the output, mod 256.  The
// first `distance` bytes have no predecessor and pass through
// unchanged.
fn decode_delta_coder(
  packed: BitArray,
  properties: BitArray,
  unpack_sizes: List(Int),
) -> Result(BitArray, error.ArchiveError) {
  let target = folder_unpack_total(unpack_sizes)
  let distance = case properties {
    <<d>> -> d + 1
    _ -> 1
  }
  let decoded = delta_decode_seven_z(packed, distance)
  verify_unpack_size(decoded, target, "Delta")
}

fn delta_decode_seven_z(bytes: BitArray, distance: Int) -> BitArray {
  let byte_list = bit_array_to_byte_list_seven_z(bytes, [])
  let decoded = delta_decode_seven_z_loop(byte_list, distance, [], 0)
  byte_list_to_bit_array_seven_z(decoded, <<>>)
}

fn bit_array_to_byte_list_seven_z(bytes: BitArray, acc: List(Int)) -> List(Int) {
  case bytes {
    <<b, rest:bytes>> -> bit_array_to_byte_list_seven_z(rest, [b, ..acc])
    _ -> list.reverse(acc)
  }
}

fn byte_list_to_bit_array_seven_z(bytes: List(Int), acc: BitArray) -> BitArray {
  case bytes {
    [] -> acc
    [b, ..rest] -> byte_list_to_bit_array_seven_z(rest, <<acc:bits, b>>)
  }
}

fn delta_decode_seven_z_loop(
  input: List(Int),
  distance: Int,
  output: List(Int),
  index: Int,
) -> List(Int) {
  case input {
    [] -> list.reverse(output)
    [b, ..rest] ->
      case index < distance {
        True ->
          delta_decode_seven_z_loop(rest, distance, [b, ..output], index + 1)
        False -> {
          // `output` holds emitted bytes in reverse order (head =
          // most recent).  The byte we emitted `distance` slots ago
          // is always at offset `distance - 1` from the head, no
          // matter how many bytes have been emitted overall.
          let predecessor = nth_back(output, distance - 1)
          let sum = int.bitwise_and(b + predecessor, 0xFF)
          delta_decode_seven_z_loop(rest, distance, [sum, ..output], index + 1)
        }
      }
  }
}

fn nth_back(values: List(Int), steps: Int) -> Int {
  case values, steps {
    [head, ..], 0 -> head
    [_, ..tail], _ -> nth_back(tail, steps - 1)
    [], _ -> 0
  }
}

fn folder_unpack_total(unpack_sizes: List(Int)) -> Int {
  case unpack_sizes {
    [size, ..] -> size
    [] -> 0
  }
}

// The Copy coder is identity: packed bytes ARE the folder's unpacked
// bytes.  7z still records the unpack size, so we cross-check and
// reject a packed slice that's smaller than the declared size (which
// would point at a truncated archive) or trim a trailing tail the
// folder slice carries past the declared end (rare, but tolerated by
// reference implementations).
fn decode_copy_coder(
  packed: BitArray,
  unpack_sizes: List(Int),
) -> Result(BitArray, error.ArchiveError) {
  let target = folder_unpack_total(unpack_sizes)
  let packed_size = bit_array.byte_size(packed)
  case packed_size >= target {
    True ->
      case bit_array.slice(packed, 0, target) {
        Ok(b) -> Ok(b)
        Error(_) ->
          Error(error.ArchiveInvalid(message: "7z Copy coder slice failed"))
      }
    False ->
      Error(error.ArchiveInvalid(
        message: "7z Copy coder packed size "
        <> int.to_string(packed_size)
        <> " < declared unpack size "
        <> int.to_string(target),
      ))
  }
}

// 7z's Deflate coder carries a raw DEFLATE stream (no zlib / gzip
// wrapper), which is exactly what `deflate.decode` expects.  Limits
// are threaded through `decode_with_limits` so a corrupted stream
// that decompresses past `max_output_bytes` surfaces as the typed
// limit error instead of allocating without bound.
fn decode_deflate_coder(
  packed: BitArray,
  unpack_sizes: List(Int),
  limits: limit.Limits,
) -> Result(BitArray, error.ArchiveError) {
  let target = folder_unpack_total(unpack_sizes)
  case deflate.decode_with_limits(bytes: packed, limits: limits) {
    Ok(plain) -> verify_unpack_size(plain, target, "Deflate")
    Error(err) -> Error(codec_to_archive(err))
  }
}

// 7z's BZip2 coder carries a complete bzip2 stream (BZh magic and
// all), so we delegate directly to `bzip2.decode_with_limits`.
fn decode_bzip2_coder(
  packed: BitArray,
  unpack_sizes: List(Int),
  limits: limit.Limits,
) -> Result(BitArray, error.ArchiveError) {
  let target = folder_unpack_total(unpack_sizes)
  case bzip2.decode_with_limits(bytes: packed, limits: limits) {
    Ok(plain) -> verify_unpack_size(plain, target, "BZip2")
    Error(err) -> Error(codec_to_archive(err))
  }
}

// Cross-check the codec output length against the folder's declared
// unpack size.  A mismatch usually means a truncated payload or
// header tampering; surface it as `ArchiveInvalid` rather than
// silently handing the caller a short or oversized buffer that would
// break later substream splitting.
fn verify_unpack_size(
  plain: BitArray,
  expected: Int,
  coder_name: String,
) -> Result(BitArray, error.ArchiveError) {
  let actual = bit_array.byte_size(plain)
  case actual == expected {
    True -> Ok(plain)
    False ->
      Error(error.ArchiveInvalid(
        message: "7z "
        <> coder_name
        <> " unpacked "
        <> int.to_string(actual)
        <> " bytes but folder declared "
        <> int.to_string(expected),
      ))
  }
}

fn decode_lzma2_payload(
  packed: BitArray,
  _props: BitArray,
  unpack_sizes: List(Int),
) -> Result(BitArray, error.ArchiveError) {
  let total = case unpack_sizes {
    [size, ..] -> size
    [] -> 0
  }
  use bytes <- result.try(decode_lzma2_stream(packed, <<>>, total))
  Ok(bytes)
}

fn decode_lzma2_stream(
  payload: BitArray,
  output: BitArray,
  target: Int,
) -> Result(BitArray, error.ArchiveError) {
  case payload {
    <<0x00, _:bytes>> -> Ok(output)
    <<control, _:bytes>> if control == 0x01 || control == 0x02 -> {
      case payload {
        <<_control, sh, sl, rest:bytes>> -> {
          let size = int.bitwise_or(int.bitwise_shift_left(sh, 8), sl) + 1
          case bit_array.slice(rest, 0, size) {
            Ok(chunk) ->
              case
                bit_array.slice(rest, size, bit_array.byte_size(rest) - size)
              {
                Ok(after) ->
                  decode_lzma2_stream(
                    after,
                    bit_array.concat([output, chunk]),
                    target,
                  )
                Error(_) ->
                  Error(error.ArchiveInvalid(
                    message: "truncated 7z LZMA2 uncompressed chunk",
                  ))
              }
            Error(_) ->
              Error(error.ArchiveInvalid(
                message: "truncated 7z LZMA2 chunk body",
              ))
          }
        }
        _ ->
          Error(error.ArchiveInvalid(message: "truncated 7z LZMA2 chunk header"))
      }
    }
    <<control, usize_high, usize_low, csize_high, csize_low, rest:bytes>>
      if control >= 0x80
    -> {
      let _ = target
      let usize =
        int.bitwise_or(
          int.bitwise_shift_left(int.bitwise_and(control, 0x1F), 16),
          int.bitwise_or(int.bitwise_shift_left(usize_high, 8), usize_low),
        )
        + 1
      let csize =
        int.bitwise_or(int.bitwise_shift_left(csize_high, 8), csize_low) + 1
      case control >= 0xC0 {
        True -> {
          case rest {
            <<props_byte, rest_after_props:bytes>> -> {
              case lzma.properties_of_byte(props_byte) {
                Ok(parsed_props) -> {
                  case bit_array.slice(rest_after_props, 0, csize) {
                    Ok(lzma_data) -> {
                      case
                        bit_array.slice(
                          rest_after_props,
                          csize,
                          bit_array.byte_size(rest_after_props) - csize,
                        )
                      {
                        Ok(after_chunk) ->
                          case lzma.new(lzma_data, parsed_props, 32_000_000) {
                            Ok(dec) ->
                              case lzma.decode_into(dec, usize) {
                                Ok(#(decoded, _state)) ->
                                  decode_lzma2_stream(
                                    after_chunk,
                                    bit_array.concat([output, decoded]),
                                    target,
                                  )
                                Error(err) -> Error(codec_to_archive(err))
                              }
                            Error(err) -> Error(codec_to_archive(err))
                          }
                        Error(_) ->
                          Error(error.ArchiveInvalid(
                            message: "truncated 7z LZMA chunk",
                          ))
                      }
                    }
                    Error(_) ->
                      Error(error.ArchiveInvalid(
                        message: "truncated 7z LZMA chunk body",
                      ))
                  }
                }
                Error(err) -> Error(codec_to_archive(err))
              }
            }
            _ ->
              Error(error.ArchiveInvalid(
                message: "truncated 7z LZMA properties byte",
              ))
          }
        }
        False ->
          Error(error.ArchiveNotImplemented(
            feature: "7z LZMA2 chunks without inline properties",
          ))
      }
    }
    _ -> Error(error.ArchiveInvalid(message: "invalid 7z LZMA2 control byte"))
  }
}

fn decode_raw_lzma(
  packed: BitArray,
  props: BitArray,
  unpack_sizes: List(Int),
) -> Result(BitArray, error.ArchiveError) {
  let target = case unpack_sizes {
    [size, ..] -> size
    [] -> 0
  }
  case props {
    <<props_byte, _:bytes>> ->
      case lzma.properties_of_byte(props_byte) {
        Ok(parsed_props) -> {
          // 7z's raw LZMA payload starts directly with the range
          // coder's 5 priming bytes (the first of which must be zero
          // per the LZMA specification).  Unlike the LZMA2 wrapper
          // used inside xz, the priming byte is NOT injected by the
          // surrounding format, so do not prepend another zero.
          case lzma.new(packed, parsed_props, 32_000_000) {
            Ok(dec) ->
              case lzma.decode_into(dec, target) {
                Ok(#(decoded, _state)) -> Ok(decoded)
                Error(err) -> Error(codec_to_archive(err))
              }
            Error(err) -> Error(codec_to_archive(err))
          }
        }
        Error(err) -> Error(codec_to_archive(err))
      }
    _ ->
      Error(error.ArchiveInvalid(
        message: "7z raw LZMA coder missing properties",
      ))
  }
}

fn codec_to_archive(err: error.CodecError) -> error.ArchiveError {
  case err {
    error.CodecNotImplemented(feature) ->
      error.ArchiveNotImplemented(feature: feature)
    error.CodecInvalidData(message) -> error.ArchiveInvalid(message: message)
    error.CodecLimitExceeded(limit, actual) ->
      error.ArchiveLimitExceeded(limit: limit, actual: actual)
    error.CodecDictionaryRequired(name) ->
      error.ArchiveInvalid(
        message: "codec " <> name <> " requires a preset dictionary",
      )
    error.CodecDictionaryMismatch(name) ->
      error.ArchiveInvalid(
        message: "codec " <> name <> " preset dictionary DICT_ID mismatch",
      )
    error.CodecOptionUnsupported(option, codec_name) ->
      error.ArchiveInvalid(
        message: "codec "
        <> codec_name
        <> " does not support the requested option: "
        <> option,
      )
  }
}

fn build_archive_entries(
  plain: BitArray,
  parsed: ParsedHeader,
  limits: limit.Limits,
) -> Result(archives.Archive, error.ArchiveError) {
  // SubStreamsInfo is optional: it's only emitted when ≥ 2 files share
  // a single folder (the solid-mode case).  Non-solid archives — and
  // single-file solid archives — omit it entirely.  Derive a synthetic
  // substream size list from the folder unpack sizes so the rest of
  // the entry loop has one size per file regardless of which shape the
  // producer wrote.
  let substream_sizes = case parsed.substream_sizes {
    [] -> derive_substream_sizes_from_folders(parsed.folder_unpack_sizes)
    values -> values
  }
  build_entries_loop(
    plain,
    parsed.file_names,
    parsed.empty_streams,
    parsed.empty_files,
    parsed.mtimes_unix,
    substream_sizes,
    0,
    [],
    limits,
  )
  |> result.map(fn(entries) {
    archives.from_entries(format: format(), entries: entries)
  })
}

// Each folder's "final" output size lives at the end of its
// `coders_unpack_size` list (the last coder in the chain emits the
// folder output).  For a 1-coder folder that's the only entry; for a
// 2-coder simple chain it's the second one.  We assume one file per
// folder, which is the only multi-folder shape packkit currently
// accepts.
fn derive_substream_sizes_from_folders(
  folder_unpack_sizes: List(List(Int)),
) -> List(Int) {
  list.map(folder_unpack_sizes, last_of_list)
}

fn last_of_list(values: List(Int)) -> Int {
  case values {
    [last] -> last
    [_, ..rest] -> last_of_list(rest)
    [] -> 0
  }
}

fn build_entries_loop(
  plain: BitArray,
  names: List(String),
  empties: List(Bool),
  empty_files: List(Bool),
  mtimes: List(Option(Int)),
  sizes: List(Int),
  consumed: Int,
  acc: List(entry.Entry),
  limits: limit.Limits,
) -> Result(List(entry.Entry), error.ArchiveError) {
  // Pull the next mtime slot.  When the Mtime block was absent the
  // input list is empty for every iteration and we treat the entry
  // as having no recorded mtime (option.None).
  let #(entry_mtime, rest_mtimes) = case mtimes {
    [m, ..rest] -> #(m, rest)
    [] -> #(option.None, [])
  }
  case names, empties {
    [], _ -> Ok(list.reverse(acc))
    [name, ..rest_names], [is_empty, ..rest_empties] ->
      case is_empty {
        True -> {
          // EmptyFile bit (when present) flips the default classification
          // from directory to empty regular file.  When EmptyFile is
          // absent the list is exhausted and we keep the historical
          // "directory" default.
          let #(is_file, rest_empty_files) = case empty_files {
            [bit, ..rest] -> #(bit, rest)
            [] -> #(False, [])
          }
          let adder = case is_file {
            True -> add_file(name, <<>>, entry_mtime, acc, limits)
            False -> add_directory(name, entry_mtime, acc, limits)
          }
          adder
          |> result.try(fn(new_acc) {
            build_entries_loop(
              plain,
              rest_names,
              rest_empties,
              rest_empty_files,
              rest_mtimes,
              sizes,
              consumed,
              new_acc,
              limits,
            )
          })
        }
        False ->
          consume_one_file_body(
            plain,
            name,
            rest_names,
            rest_empties,
            empty_files,
            entry_mtime,
            rest_mtimes,
            sizes,
            consumed,
            acc,
            limits,
          )
      }
    [name, ..rest_names], [] ->
      consume_one_file_body(
        plain,
        name,
        rest_names,
        [],
        empty_files,
        entry_mtime,
        rest_mtimes,
        sizes,
        consumed,
        acc,
        limits,
      )
  }
}

fn consume_one_file_body(
  plain: BitArray,
  name: String,
  rest_names: List(String),
  rest_empties: List(Bool),
  empty_files: List(Bool),
  entry_mtime: Option(Int),
  rest_mtimes: List(Option(Int)),
  sizes: List(Int),
  consumed: Int,
  acc: List(entry.Entry),
  limits: limit.Limits,
) -> Result(List(entry.Entry), error.ArchiveError) {
  // Pull the next file size from the SubStreamsInfo when one was
  // declared; otherwise fall back to "all the remaining bytes" so
  // single-file archives that omit SubStreamsInfo keep working.
  let #(this_size, next_sizes) = case sizes {
    [s, ..rest] -> #(s, rest)
    [] -> #(bit_array.byte_size(plain) - consumed, [])
  }
  let assert Ok(body) = bit_array.slice(plain, consumed, this_size)
  add_file(name, body, entry_mtime, acc, limits)
  |> result.try(fn(new_acc) {
    build_entries_loop(
      plain,
      rest_names,
      rest_empties,
      empty_files,
      rest_mtimes,
      next_sizes,
      consumed + this_size,
      new_acc,
      limits,
    )
  })
}

fn apply_mtime(e: entry.Entry, mtime: Option(Int)) -> entry.Entry {
  case mtime {
    option.Some(unix_seconds) if unix_seconds > 0 ->
      entry.with_modified_at(e, unix_seconds: unix_seconds)
    _ -> e
  }
}

fn add_file(
  name: String,
  body: BitArray,
  mtime: Option(Int),
  acc: List(entry.Entry),
  limits: limit.Limits,
) -> Result(List(entry.Entry), error.ArchiveError) {
  case entry.file_checked(path: name, body: body) {
    Ok(e) -> {
      let depth = entry.depth(entry.path(e))
      case depth > limit.max_entry_depth(limits) {
        True ->
          Error(error.ArchiveLimitExceeded(
            limit: "max_entry_depth",
            actual: depth,
          ))
        False -> Ok([apply_mtime(e, mtime), ..acc])
      }
    }
    Error(_) ->
      Error(error.ArchiveInvalid(
        message: "7z file name failed path validation: " <> name,
      ))
  }
}

fn add_directory(
  name: String,
  mtime: Option(Int),
  acc: List(entry.Entry),
  limits: limit.Limits,
) -> Result(List(entry.Entry), error.ArchiveError) {
  case entry.directory_checked(path: name) {
    Ok(e) -> {
      let depth = entry.depth(entry.path(e))
      case depth > limit.max_entry_depth(limits) {
        True ->
          Error(error.ArchiveLimitExceeded(
            limit: "max_entry_depth",
            actual: depth,
          ))
        False -> Ok([apply_mtime(e, mtime), ..acc])
      }
    }
    Error(_) ->
      Error(error.ArchiveInvalid(
        message: "7z directory name failed path validation: " <> name,
      ))
  }
}

// -- byte / number helpers ---------------------------------------------

fn slice_required(
  bytes: BitArray,
  offset: Int,
  length: Int,
  label: String,
) -> Result(BitArray, error.ArchiveError) {
  case bit_array.slice(bytes, offset, length) {
    Ok(value) -> Ok(value)
    Error(_) -> Error(error.ArchiveInvalid(message: "truncated " <> label))
  }
}

fn read_number(bytes: BitArray) -> Result(#(Int, BitArray), error.ArchiveError) {
  case bytes {
    <<first, rest:bytes>> -> read_number_body(first, rest, 0x80, 0, 0)
    _ -> Error(error.ArchiveInvalid(message: "truncated 7z varint"))
  }
}

fn read_number_body(
  first: Int,
  rest: BitArray,
  mask: Int,
  index: Int,
  value: Int,
) -> Result(#(Int, BitArray), error.ArchiveError) {
  case index >= 8 {
    True -> Ok(#(value, rest))
    False ->
      case int.bitwise_and(first, mask) {
        0 -> {
          let high_part = int.bitwise_and(first, mask - 1)
          let final_value = value + int.bitwise_shift_left(high_part, index * 8)
          Ok(#(final_value, rest))
        }
        _ ->
          case rest {
            <<byte, more:bytes>> ->
              read_number_body(
                first,
                more,
                int.bitwise_shift_right(mask, 1),
                index + 1,
                value + int.bitwise_shift_left(byte, index * 8),
              )
            _ ->
              Error(error.ArchiveInvalid(
                message: "truncated 7z multi-byte varint",
              ))
          }
      }
  }
}

fn read_numbers(
  bytes: BitArray,
  count: Int,
) -> Result(#(List(Int), BitArray), error.ArchiveError) {
  read_numbers_loop(bytes, count, [])
}

fn read_numbers_loop(
  bytes: BitArray,
  remaining: Int,
  acc: List(Int),
) -> Result(#(List(Int), BitArray), error.ArchiveError) {
  case remaining {
    0 -> Ok(#(list.reverse(acc), bytes))
    _ -> {
      use #(value, rest) <- result.try(read_number(bytes))
      read_numbers_loop(rest, remaining - 1, [value, ..acc])
    }
  }
}
