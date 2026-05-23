//// 7z archive — minimal pure-Gleam reader.
////
//// The reader handles the common case produced by `7z a` on a small
//// payload: a single packed stream wrapped in a single folder that
//// uses one coder, either raw LZMA (`0x03 0x01 0x01`) or LZMA2
//// (`0x21`).  Multi-coder folders, BCJ filters, encryption, and the
//// encoded-header form (`NID 0x17`) are intentionally rejected with
//// typed `ArchiveNotImplemented` errors so the reader is easy to
//// extend incrementally.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/result
import packkit/archive as archives
import packkit/entry
import packkit/error
import packkit/internal/lzma

const signature_size: Int = 32

const lzma2_coder_id: Int = 0x21

const lzma_coder_id_high: Int = 0x03

const lzma_coder_id_mid: Int = 0x01

const lzma_coder_id_low: Int = 0x01

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

/// Encode a logical archive to a 7z byte stream.  Not yet implemented.
pub fn encode(
  archive _archive_value: archives.Archive,
) -> Result(BitArray, error.ArchiveError) {
  Error(error.ArchiveNotImplemented(feature: "seven_z.encode"))
}

/// Decode a 7z byte stream.
pub fn decode(
  bytes bytes: BitArray,
) -> Result(archives.Archive, error.ArchiveError) {
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
      decode_encoded_header(rest, bytes)
    _ -> Ok(next_header_bytes)
  })
  use parsed <- result.try(parse_header(header))
  decode_archive(packed_streams, parsed)
}

// -- encoded next header (NID 0x17) ------------------------------------

fn decode_encoded_header(
  bytes_after_nid: BitArray,
  full_archive: BitArray,
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
    HeaderStreamsParsed(pack_pos, pack_sizes, folder, unpack_sizes) -> {
      let pack_offset = signature_size + pack_pos
      let pack_size = sum_list(pack_sizes, 0)
      use packed <- result.try(slice_required(
        full_archive,
        pack_offset,
        pack_size,
        "7z encoded-header packed bytes",
      ))
      decode_folder(packed, folder, unpack_sizes)
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
    folder: ParsedFolder,
    unpack_sizes: List(Int),
    file_names: List(String),
    empty_streams: List(Bool),
  )
}

type ParsedFolder {
  ParsedFolder(coder_id: CoderId, properties: BitArray)
}

type CoderId {
  Lzma2
  Lzma
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
    folder: ParsedFolder,
    unpack_sizes: List(Int),
  )
}

type HeaderFiles {
  HeaderFilesNone
  HeaderFilesParsed(names: List(String), empty_streams: List(Bool))
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
    HeaderStreamsParsed(pack_pos, pack_sizes, folder, unpack_sizes),
      HeaderFilesParsed(names, empty_streams)
    ->
      Ok(ParsedHeader(
        pack_pos: pack_pos,
        pack_sizes: pack_sizes,
        folder: folder,
        unpack_sizes: unpack_sizes,
        file_names: names,
        empty_streams: empty_streams,
      ))
    HeaderStreamsParsed(pack_pos, pack_sizes, folder, unpack_sizes),
      HeaderFilesNone
    ->
      Ok(
        ParsedHeader(
          pack_pos: pack_pos,
          pack_sizes: pack_sizes,
          folder: folder,
          unpack_sizes: unpack_sizes,
          file_names: [],
          empty_streams: [],
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
      folder: None,
      unpack_sizes: [],
      have_pack: False,
      have_unpack: False,
    )
  parse_streams_loop(bytes, state)
}

type StreamsParser {
  StreamsParser(
    pack_pos: Int,
    pack_sizes: List(Int),
    folder: OptionalFolder,
    unpack_sizes: List(Int),
    have_pack: Bool,
    have_unpack: Bool,
  )
}

type OptionalFolder {
  None
  Some(folder: ParsedFolder)
}

fn parse_streams_loop(
  bytes: BitArray,
  state: StreamsParser,
) -> Result(#(HeaderStreams, BitArray), error.ArchiveError) {
  case bytes {
    <<nid, rest:bytes>> ->
      case nid {
        n if n == nid_end ->
          case state.folder {
            Some(folder) ->
              Ok(#(
                HeaderStreamsParsed(
                  pack_pos: state.pack_pos,
                  pack_sizes: state.pack_sizes,
                  folder: folder,
                  unpack_sizes: state.unpack_sizes,
                ),
                rest,
              ))
            None ->
              Error(error.ArchiveInvalid(
                message: "7z MainStreamsInfo missing UnPackInfo",
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
          use #(folder, unpack_sizes, rest) <- result.try(parse_unpack_info(
            rest,
          ))
          parse_streams_loop(
            rest,
            StreamsParser(
              ..state,
              folder: Some(folder),
              unpack_sizes: unpack_sizes,
              have_unpack: True,
            ),
          )
        }
        n if n == nid_sub_streams_info -> {
          use rest <- result.try(skip_sub_streams_info(rest, 1))
          parse_streams_loop(rest, state)
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
) -> Result(#(ParsedFolder, List(Int), BitArray), error.ArchiveError) {
  parse_unpack_info_body(bytes, None, [])
}

fn parse_unpack_info_body(
  bytes: BitArray,
  folder: OptionalFolder,
  unpack_sizes: List(Int),
) -> Result(#(ParsedFolder, List(Int), BitArray), error.ArchiveError) {
  case bytes {
    <<nid, rest:bytes>> ->
      case nid {
        n if n == nid_end ->
          case folder {
            Some(f) -> Ok(#(f, unpack_sizes, rest))
            None ->
              Error(error.ArchiveInvalid(
                message: "7z UnPackInfo missing Folder section",
              ))
          }
        n if n == nid_folder -> {
          use #(folder, rest) <- result.try(parse_folders(rest))
          parse_unpack_info_body(rest, Some(folder), unpack_sizes)
        }
        n if n == nid_coders_unpack_size -> {
          use #(sizes, rest) <- result.try(read_numbers(rest, 1))
          parse_unpack_info_body(rest, folder, sizes)
        }
        n if n == nid_crc -> {
          use rest <- result.try(skip_crc_block(rest, 1))
          parse_unpack_info_body(rest, folder, unpack_sizes)
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
) -> Result(#(ParsedFolder, BitArray), error.ArchiveError) {
  use #(num_folders, rest) <- result.try(read_number(bytes))
  use <- bool.guard(
    when: num_folders != 1,
    return: Error(error.ArchiveNotImplemented(
      feature: "7z archives with multiple folders",
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
      parse_single_folder(after_external)
    }
    _ -> Error(error.ArchiveInvalid(message: "truncated 7z folder section"))
  }
}

fn parse_single_folder(
  bytes: BitArray,
) -> Result(#(ParsedFolder, BitArray), error.ArchiveError) {
  use #(num_coders, rest) <- result.try(read_number(bytes))
  use <- bool.guard(
    when: num_coders != 1,
    return: Error(error.ArchiveNotImplemented(
      feature: "7z folders with multiple coders",
    )),
  )
  case rest {
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
          Ok(#(
            ParsedFolder(coder_id: coder_id, properties: <<>>),
            after_coder_id,
          ))
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
          Ok(#(ParsedFolder(coder_id: coder_id, properties: attrs), after_attrs))
        }
      }
    }
    _ -> Error(error.ArchiveInvalid(message: "truncated 7z coder definition"))
  }
}

fn classify_coder_id(id_bytes: BitArray) -> Result(CoderId, error.ArchiveError) {
  case id_bytes {
    <<b>> if b == lzma2_coder_id -> Ok(Lzma2)
    <<b1, b2, b3>>
      if b1 == lzma_coder_id_high
      && b2 == lzma_coder_id_mid
      && b3 == lzma_coder_id_low
    -> Ok(Lzma)
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
  parse_files_loop(rest, num_files, [], [])
}

fn parse_files_loop(
  bytes: BitArray,
  num_files: Int,
  names: List(String),
  empty_streams: List(Bool),
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
          parse_files_loop(after_payload, num_files, names, flags)
        }
        n
          if n == nid_dummy
          || n == nid_ctime
          || n == nid_atime
          || n == nid_mtime
          || n == nid_win_attributes
          || n == nid_empty_file
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
          parse_files_loop(after_payload, num_files, names, empty_streams)
        }
        _ ->
          Error(error.ArchiveInvalid(
            message: "unexpected 7z FilesInfo NID " <> int.to_string(nid),
          ))
      }
    _ -> Error(error.ArchiveInvalid(message: "truncated 7z FilesInfo"))
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
fn skip_sub_streams_info(
  bytes: BitArray,
  num_folders: Int,
) -> Result(BitArray, error.ArchiveError) {
  sub_streams_loop(bytes, num_folders, 0)
}

fn sub_streams_loop(
  bytes: BitArray,
  num_folders: Int,
  num_substreams_total: Int,
) -> Result(BitArray, error.ArchiveError) {
  case bytes {
    <<nid, rest:bytes>> ->
      case nid {
        n if n == nid_end -> Ok(rest)
        0x0D -> {
          // kNumUnPackStream: one varint per folder
          use #(counts, rest) <- result.try(read_numbers(rest, num_folders))
          let total = sum_list(counts, 0)
          sub_streams_loop(rest, num_folders, total)
        }
        n if n == nid_size -> {
          let count = case num_substreams_total {
            0 -> 0
            _ -> num_substreams_total - num_folders
          }
          let safe_count = case count > 0 {
            True -> count
            False -> 0
          }
          use #(_, rest) <- result.try(read_numbers(rest, safe_count))
          sub_streams_loop(rest, num_folders, num_substreams_total)
        }
        n if n == nid_crc -> {
          let count = case num_substreams_total {
            0 -> num_folders
            _ -> num_substreams_total
          }
          use rest <- result.try(skip_crc_block(rest, count))
          sub_streams_loop(rest, num_folders, num_substreams_total)
        }
        _ ->
          Error(error.ArchiveInvalid(
            message: "unexpected 7z SubStreamsInfo NID " <> int.to_string(nid),
          ))
      }
    _ -> Error(error.ArchiveInvalid(message: "truncated 7z SubStreamsInfo"))
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
) -> Result(archives.Archive, error.ArchiveError) {
  let _ = parsed.pack_pos
  use plain <- result.try(decode_folder(
    packed,
    parsed.folder,
    parsed.unpack_sizes,
  ))
  build_archive_entries(plain, parsed)
}

fn decode_folder(
  packed: BitArray,
  folder: ParsedFolder,
  unpack_sizes: List(Int),
) -> Result(BitArray, error.ArchiveError) {
  case folder.coder_id {
    Lzma2 -> decode_lzma2_payload(packed, folder.properties, unpack_sizes)
    Lzma -> decode_raw_lzma(packed, folder.properties, unpack_sizes)
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
    error.CodecLimitExceeded(limit, value) ->
      error.ArchiveLimitExceeded(limit: limit, value: value)
    error.CodecUnsupported(name) ->
      error.ArchiveNotImplemented(feature: "codec " <> name)
    error.CodecDictionaryRequired(name) ->
      error.ArchiveInvalid(
        message: "codec " <> name <> " requires a preset dictionary",
      )
  }
}

fn build_archive_entries(
  plain: BitArray,
  parsed: ParsedHeader,
) -> Result(archives.Archive, error.ArchiveError) {
  build_entries_loop(plain, parsed.file_names, parsed.empty_streams, 0, [])
  |> result.map(fn(entries) {
    archives.from_entries(format: format(), entries: entries)
  })
}

fn build_entries_loop(
  plain: BitArray,
  names: List(String),
  empties: List(Bool),
  consumed: Int,
  acc: List(entry.Entry),
) -> Result(List(entry.Entry), error.ArchiveError) {
  case names, empties {
    [], _ -> Ok(list.reverse(acc))
    [name, ..rest_names], [is_empty, ..rest_empties] ->
      case is_empty {
        True ->
          add_directory(name, acc)
          |> result.try(fn(new_acc) {
            build_entries_loop(
              plain,
              rest_names,
              rest_empties,
              consumed,
              new_acc,
            )
          })
        False -> {
          let remaining = bit_array.byte_size(plain) - consumed
          let assert Ok(body) = bit_array.slice(plain, consumed, remaining)
          add_file(name, body, acc)
          |> result.try(fn(new_acc) {
            build_entries_loop(
              plain,
              rest_names,
              rest_empties,
              consumed + remaining,
              new_acc,
            )
          })
        }
      }
    [name, ..rest_names], [] -> {
      let remaining = bit_array.byte_size(plain) - consumed
      let assert Ok(body) = bit_array.slice(plain, consumed, remaining)
      add_file(name, body, acc)
      |> result.try(fn(new_acc) {
        build_entries_loop(plain, rest_names, [], consumed + remaining, new_acc)
      })
    }
  }
}

fn add_file(
  name: String,
  body: BitArray,
  acc: List(entry.Entry),
) -> Result(List(entry.Entry), error.ArchiveError) {
  case entry.file_checked(path: name, body: body) {
    Ok(e) -> Ok([e, ..acc])
    Error(_) ->
      Error(error.ArchiveInvalid(
        message: "7z file name failed path validation: " <> name,
      ))
  }
}

fn add_directory(
  name: String,
  acc: List(entry.Entry),
) -> Result(List(entry.Entry), error.ArchiveError) {
  case entry.directory_checked(path: name) {
    Ok(e) -> Ok([e, ..acc])
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
