//// Zstandard codec — pure-Gleam decoder.
////
//// The module parses the Zstandard frame envelope (magic, frame
//// header descriptor, window descriptor, optional dictionary id,
//// optional frame content size, optional trailing content checksum)
//// and walks the block stream.  Raw and RLE blocks decode directly;
//// compressed blocks (type 2) decode through the FSE tables in
//// `packkit/internal/fse`.  Sequences with `Predefined_Mode`,
//// `RLE_Mode`, and `FSE_Compressed_Mode` symbol descriptions all
//// decode (LL, OF, ML independently).  All four literal block
//// types decode: `Raw_Literals_Block`, `RLE_Literals_Block`,
//// `Compressed_Literals_Block` (Huffman-coded with direct-weight
//// or FSE-weight tree descriptions, 1-stream or 4-stream form),
//// and `Treeless_Literals_Block` (which reuses the prior block's
//// Huffman tree via the cross-block tree state threaded through
//// the block loop).  A treeless block in the first position of a
//// frame surfaces as a typed `CodecInvalidData`.  `Repeat_Mode`
//// for sequence-symbol descriptions also threads its FSE tables
//// across blocks (per RFC 8478 §3.1.1.4 the LL / OF / ML tables
//// survive across blocks within a frame), and a Repeat_Mode in the
//// first block of a frame surfaces as a typed `CodecInvalidData`.

import gleam/bit_array
import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import packkit/codec as codecs
import packkit/error
import packkit/internal/fse
import packkit/internal/huf
import packkit/limit

const magic: Int = 0xFD2FB528

/// Zstandard codec smart constructor.
pub fn codec() -> codecs.Codec {
  codecs.zstd()
}

const max_block_size: Int = 0x20_000

/// Encode `bytes` as a Zstandard frame.  The encoder picks the
/// cheapest of `Raw_Block` and `RLE_Block` per chunk — a chunk that
/// repeats a single byte collapses to a 1-byte RLE payload — so
/// inputs like `repeat('A', N)` compress, but mixed input still
/// passes through as raw bytes.  No LZ77 or Huffman compression yet,
/// no content checksum.  Output is a valid Zstandard frame any
/// conforming decoder can read.
pub fn encode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  let size = bit_array.byte_size(bytes)
  use header <- result.try(frame_header_for_size(size))
  let blocks = build_raw_blocks(bytes, size)
  Ok(bit_array.concat([header, blocks]))
}

/// Build the Zstandard frame header for a payload of `size` bytes.
/// Exposed for tests that need to assert on the FCS layout for sizes
/// too large to materialise in memory (e.g. 4 GiB+ frames where the
/// header used to silently truncate the FCS field to its low 32 bits).
pub fn frame_header_for_size(size: Int) -> Result(BitArray, error.CodecError) {
  // Single_Segment_flag = 1, no Window_Descriptor, no Dictionary_ID,
  // no Content_Checksum.  FCS encoding follows the size — 1 byte for
  // < 256, 2 bytes (FCS_flag = 1) for the 256..65535 range, 4 bytes
  // (FCS_flag = 2) for the 65536..(2^32)-1 range, otherwise 8 bytes
  // (FCS_flag = 3).
  case size {
    n if n < 256 -> Ok(<<0x28, 0xB5, 0x2F, 0xFD, 0x20, n>>)
    n if n < 0x1_0000 ->
      Ok(<<
        0x28,
        0xB5,
        0x2F,
        0xFD,
        0x60,
        { n - 256 }:size(16)-little,
      >>)
    n if n < 0x1_0000_0000 ->
      Ok(<<
        0x28,
        0xB5,
        0x2F,
        0xFD,
        0xA0,
        n:size(32)-little,
      >>)
    n -> {
      // FCS_flag = 3: full unsigned 64-bit little-endian field.
      // The previous encoder packed `n` into the low 32 bits and a
      // literal `0` into the high 32 bits, silently truncating any
      // payload at or above 4 GiB to `n mod 2^32` bytes.  The 2^64
      // ceiling is enforced by checking the high half rather than via
      // a literal upper bound, because 0xFFFFFFFFFFFFFFFF would warn
      // as outside JavaScript's safe-integer range on that target.
      let lo = int.bitwise_and(n, 0xFFFFFFFF)
      let high_half = int.bitwise_shift_right(n, 32)
      use <- bool.guard(
        when: high_half > 0xFFFFFFFF,
        return: Error(error.CodecLimitExceeded(
          limit: "zstd frame_content_size",
          actual: n,
        )),
      )
      let hi = int.bitwise_and(high_half, 0xFFFFFFFF)
      Ok(<<
        0x28,
        0xB5,
        0x2F,
        0xFD,
        0xE0,
        lo:size(32)-little,
        hi:size(32)-little,
      >>)
    }
  }
}

fn build_raw_blocks(bytes: BitArray, total: Int) -> BitArray {
  case total {
    0 -> block_header(0, 0, True)
    _ -> emit_raw_blocks_loop(bytes, total, <<>>)
  }
}

fn emit_raw_blocks_loop(
  remaining_bytes: BitArray,
  remaining_size: Int,
  acc: BitArray,
) -> BitArray {
  case remaining_size {
    0 -> acc
    n -> {
      let chunk_size = case n > max_block_size {
        True -> max_block_size
        False -> n
      }
      let is_last = chunk_size == n
      let assert Ok(chunk) = bit_array.slice(remaining_bytes, 0, chunk_size)
      let assert Ok(rest) =
        bit_array.slice(
          remaining_bytes,
          chunk_size,
          bit_array.byte_size(remaining_bytes) - chunk_size,
        )
      // Pick RLE when the whole chunk is one repeating byte and the
      // run is long enough that the 1-byte RLE payload beats N raw
      // bytes (always true for chunk_size >= 2).
      let chunk_block = case chunk_size >= 2, peek_uniform_byte(chunk) {
        True, Ok(byte) ->
          bit_array.concat([block_header(chunk_size, 1, is_last), <<byte>>])
        _, _ -> bit_array.concat([block_header(chunk_size, 0, is_last), chunk])
      }
      emit_raw_blocks_loop(
        rest,
        remaining_size - chunk_size,
        bit_array.concat([acc, chunk_block]),
      )
    }
  }
}

/// Returns the single byte the whole chunk repeats, or Error if the
/// chunk has more than one distinct value.
fn peek_uniform_byte(bytes: BitArray) -> Result(Int, Nil) {
  case bytes {
    <<first, rest:bytes>> -> uniform_byte_loop(first, rest)
    _ -> Error(Nil)
  }
}

fn uniform_byte_loop(byte: Int, rest: BitArray) -> Result(Int, Nil) {
  case rest {
    <<>> -> Ok(byte)
    <<b, more:bytes>> if b == byte -> uniform_byte_loop(byte, more)
    _ -> Error(Nil)
  }
}

fn block_header(block_size: Int, block_type: Int, is_last: Bool) -> BitArray {
  let last_bit = case is_last {
    True -> 1
    False -> 0
  }
  // header layout: [block_size:21][block_type:2][last:1]
  let block_header_value =
    int.bitwise_or(
      int.bitwise_or(
        int.bitwise_shift_left(block_size, 3),
        int.bitwise_shift_left(block_type, 1),
      ),
      last_bit,
    )
  let bh0 = int.bitwise_and(block_header_value, 0xFF)
  let bh1 =
    int.bitwise_and(int.bitwise_shift_right(block_header_value, 8), 0xFF)
  let bh2 =
    int.bitwise_and(int.bitwise_shift_right(block_header_value, 16), 0xFF)
  <<bh0, bh1, bh2>>
}

/// Decode a Zstandard frame using default limits.
pub fn decode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  decode_with_limits(bytes: bytes, limits: limit.default())
}

/// Decode a Zstandard frame using explicit limits.  Per RFC 8478 §3,
/// a zstd "byte stream" is one or more frames concatenated; the
/// decoder walks the entire input, appending each frame's payload to
/// the result.
pub fn decode_with_limits(
  bytes bytes: BitArray,
  limits limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  use <- bool.guard(
    when: bit_array.byte_size(bytes) > limit.max_input_bytes(limits),
    return: Error(error.CodecLimitExceeded(
      limit: "max_input_bytes",
      actual: bit_array.byte_size(bytes),
    )),
  )

  decode_frames_loop(bytes, <<>>, 0, limits)
}

fn decode_frames_loop(
  bytes: BitArray,
  acc: BitArray,
  accumulated_size: Int,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  // Skippable frames (RFC 8478 §3.1.2) have magic 0x184D2A5X for X
  // in 0..F.  The 4-byte LE Frame_Size that follows tells us how
  // many bytes of User_Data to skip.  The decoder must skip them
  // and then look for the next frame.
  case bytes {
    <<m:little-unsigned-size(32), _:bytes>>
      if m >= 0x184D2A50 && m <= 0x184D2A5F
    -> skip_skippable_frame(bytes, acc, accumulated_size, limits)
    _ -> decode_data_frame(bytes, acc, accumulated_size, limits)
  }
}

fn decode_data_frame(
  bytes: BitArray,
  acc: BitArray,
  accumulated_size: Int,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  use #(checksum_flag, rest) <- result.try(parse_frame_header(bytes))
  use #(output, rest) <- result.try(decode_blocks(
    rest,
    <<>>,
    limits,
    initial_block_state,
  ))
  use rest <- result.try(consume_checksum_returning_rest(rest, checksum_flag))
  let next_size = accumulated_size + bit_array.byte_size(output)
  case next_size > limit.max_output_bytes(limits) {
    True ->
      Error(error.CodecLimitExceeded(
        limit: "max_output_bytes",
        actual: next_size,
      ))
    False -> {
      let acc = bit_array.concat([acc, output])
      case bit_array.byte_size(rest) {
        0 -> Ok(acc)
        _ -> decode_frames_loop(rest, acc, next_size, limits)
      }
    }
  }
}

fn skip_skippable_frame(
  bytes: BitArray,
  acc: BitArray,
  accumulated_size: Int,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  case bytes {
    <<_magic:bytes-size(4), frame_size:little-unsigned-size(32), rest:bytes>> ->
      case bit_array.byte_size(rest) >= frame_size {
        False ->
          Error(error.CodecInvalidData(
            message: "zstd skippable frame body is shorter than the declared Frame_Size",
          ))
        True ->
          case
            bit_array.slice(
              rest,
              frame_size,
              bit_array.byte_size(rest) - frame_size,
            )
          {
            Ok(after_skip) ->
              case bit_array.byte_size(after_skip) {
                0 -> Ok(acc)
                _ ->
                  decode_frames_loop(after_skip, acc, accumulated_size, limits)
              }
            Error(_) ->
              Error(error.CodecInvalidData(
                message: "zstd skippable frame slice failed",
              ))
          }
      }
    _ ->
      Error(error.CodecInvalidData(
        message: "zstd skippable frame header is shorter than 8 bytes",
      ))
  }
}

fn consume_checksum_returning_rest(
  bytes: BitArray,
  checksum_flag: Bool,
) -> Result(BitArray, error.CodecError) {
  case checksum_flag {
    False -> Ok(bytes)
    True ->
      case bytes {
        <<_crc:bytes-size(4), rest:bytes>> -> Ok(rest)
        _ ->
          Error(error.CodecInvalidData(
            message: "zstd content checksum is shorter than 4 bytes",
          ))
      }
  }
}

// -- frame header -------------------------------------------------------

fn parse_frame_header(
  bytes: BitArray,
) -> Result(#(Bool, BitArray), error.CodecError) {
  case bytes {
    <<m:little-unsigned-size(32), rest:bytes>> if m == magic ->
      parse_frame_descriptor(rest)
    _ -> Error(error.CodecInvalidData(message: "missing zstd frame magic"))
  }
}

fn parse_frame_descriptor(
  bytes: BitArray,
) -> Result(#(Bool, BitArray), error.CodecError) {
  case bytes {
    <<descriptor, rest:bytes>> -> {
      let fcs_flag = int.bitwise_shift_right(descriptor, 6)
      let single_segment = int.bitwise_and(descriptor, 0x20) != 0
      let reserved_bit = int.bitwise_and(descriptor, 0x08) != 0
      let checksum_flag = int.bitwise_and(descriptor, 0x04) != 0
      let dict_id_flag = int.bitwise_and(descriptor, 0x03)
      use <- bool.guard(
        when: reserved_bit,
        return: Error(error.CodecInvalidData(
          message: "zstd reserved descriptor bit must be zero",
        )),
      )
      use rest <- result.try(case single_segment {
        True -> Ok(rest)
        False -> skip_window_descriptor(rest)
      })
      use rest <- result.try(skip_dictionary_id(rest, dict_id_flag))
      use rest <- result.try(skip_frame_content_size(
        rest,
        fcs_flag,
        single_segment,
      ))
      Ok(#(checksum_flag, rest))
    }
    _ -> Error(error.CodecInvalidData(message: "truncated zstd frame header"))
  }
}

fn skip_window_descriptor(bytes: BitArray) -> Result(BitArray, error.CodecError) {
  case bytes {
    <<_window, rest:bytes>> -> Ok(rest)
    _ ->
      Error(error.CodecInvalidData(message: "truncated zstd window descriptor"))
  }
}

fn skip_dictionary_id(
  bytes: BitArray,
  flag: Int,
) -> Result(BitArray, error.CodecError) {
  let size = case flag {
    0 -> 0
    1 -> 1
    2 -> 2
    3 -> 4
    _ -> 0
  }
  drop_bytes(bytes, size, "zstd dictionary id")
}

fn skip_frame_content_size(
  bytes: BitArray,
  flag: Int,
  single_segment: Bool,
) -> Result(BitArray, error.CodecError) {
  let size = case flag {
    0 ->
      case single_segment {
        True -> 1
        False -> 0
      }
    1 -> 2
    2 -> 4
    3 -> 8
    _ -> 0
  }
  drop_bytes(bytes, size, "zstd frame content size")
}

// -- block driver -------------------------------------------------------

/// Snapshot of all per-frame block-to-block state that the zstd
/// decoder must thread between successive compressed blocks: the
/// most recently parsed Huffman literal tree (for treeless literals)
/// and the LL / OF / ML FSE tables (for Repeat_Mode).
type BlockState {
  BlockState(huffman: Option(huf.Tree), sequences: SeqTablesState)
}

type SeqTablesState {
  SeqTablesState(
    ll: Option(#(dict.Dict(Int, fse.StateEntry), Int)),
    of: Option(#(dict.Dict(Int, fse.StateEntry), Int)),
    ml: Option(#(dict.Dict(Int, fse.StateEntry), Int)),
  )
}

const initial_block_state: BlockState = BlockState(
  huffman: None,
  sequences: SeqTablesState(ll: None, of: None, ml: None),
)

fn decode_blocks(
  bytes: BitArray,
  output: BitArray,
  limits: limit.Limits,
  state: BlockState,
) -> Result(#(BitArray, BitArray), error.CodecError) {
  case bytes {
    <<b0, b1, b2, rest:bytes>> -> {
      let header =
        int.bitwise_or(
          b0,
          int.bitwise_or(
            int.bitwise_shift_left(b1, 8),
            int.bitwise_shift_left(b2, 16),
          ),
        )
      let last = int.bitwise_and(header, 0x1) == 1
      let block_type = int.bitwise_and(int.bitwise_shift_right(header, 1), 0x3)
      let block_size = int.bitwise_shift_right(header, 3)
      use #(plain, rest, next_state) <- result.try(decode_one_block(
        rest,
        block_type,
        block_size,
        state,
      ))
      use new_output <- result.try(append_with_limit(output, plain, limits))
      case last {
        True -> Ok(#(new_output, rest))
        False -> decode_blocks(rest, new_output, limits, next_state)
      }
    }
    _ -> Error(error.CodecInvalidData(message: "truncated zstd block header"))
  }
}

fn decode_one_block(
  bytes: BitArray,
  block_type: Int,
  block_size: Int,
  state: BlockState,
) -> Result(#(BitArray, BitArray, BlockState), error.CodecError) {
  case block_type {
    0 ->
      decode_raw_block(bytes, block_size)
      |> result.map(fn(pair) { #(pair.0, pair.1, state) })
    1 ->
      decode_rle_block(bytes, block_size)
      |> result.map(fn(pair) { #(pair.0, pair.1, state) })
    2 -> decode_compressed_block(bytes, block_size, state)
    _ -> Error(error.CodecInvalidData(message: "zstd reserved block type 3"))
  }
}

// -- compressed block --------------------------------------------------

fn decode_compressed_block(
  bytes: BitArray,
  block_size: Int,
  state: BlockState,
) -> Result(#(BitArray, BitArray, BlockState), error.CodecError) {
  use payload <- result.try(slice_or_error(
    bytes,
    0,
    block_size,
    "zstd compressed block payload",
  ))
  let assert Ok(rest) =
    bit_array.slice(bytes, block_size, bit_array.byte_size(bytes) - block_size)

  use #(literals, after_literals, next_huffman) <- result.try(
    parse_literals_section(payload, state.huffman),
  )
  use #(plain, next_sequences) <- result.try(parse_and_apply_sequences(
    after_literals,
    literals,
    state.sequences,
  ))
  Ok(#(
    plain,
    rest,
    BlockState(huffman: next_huffman, sequences: next_sequences),
  ))
}

// -- literals section --------------------------------------------------

fn parse_literals_section(
  bytes: BitArray,
  prev_tree: Option(huf.Tree),
) -> Result(#(BitArray, BitArray, Option(huf.Tree)), error.CodecError) {
  case bytes {
    <<header_byte, _:bytes>> -> {
      let literals_block_type = int.bitwise_and(header_byte, 0x3)
      let size_format =
        int.bitwise_and(int.bitwise_shift_right(header_byte, 2), 0x3)
      case literals_block_type {
        0 ->
          parse_raw_or_rle_literals(bytes, header_byte, size_format, False)
          |> result.map(fn(pair) { #(pair.0, pair.1, prev_tree) })
        1 ->
          parse_raw_or_rle_literals(bytes, header_byte, size_format, True)
          |> result.map(fn(pair) { #(pair.0, pair.1, prev_tree) })
        2 ->
          parse_compressed_literals(
            bytes,
            header_byte,
            size_format,
            False,
            prev_tree,
          )
        _ ->
          parse_compressed_literals(
            bytes,
            header_byte,
            size_format,
            True,
            prev_tree,
          )
      }
    }
    _ ->
      Error(error.CodecInvalidData(message: "truncated zstd literals header"))
  }
}

/// Parsed metadata for a compressed or treeless literals block.
type CompressedLiteralsHeader {
  CompressedLiteralsHeader(
    /// Number of literal bytes to materialise.
    regenerated_size: Int,
    /// Number of bytes after the literals section header that make
    /// up the Huffman_Tree_Description (if any), Jump_Table (if
    /// `streams == 4`), and per-stream compressed bitstreams.
    compressed_size: Int,
    /// Number of compressed Huffman bitstreams (1 or 4).
    streams: Int,
    /// Bytes consumed by the literals section header itself
    /// (3, 4, or 5 depending on the size format).
    header_bytes: Int,
  )
}

fn parse_compressed_literals(
  bytes: BitArray,
  header_byte: Int,
  size_format: Int,
  treeless: Bool,
  prev_tree: Option(huf.Tree),
) -> Result(#(BitArray, BitArray, Option(huf.Tree)), error.CodecError) {
  use header <- result.try(parse_compressed_literals_header(
    bytes,
    header_byte,
    size_format,
  ))
  case treeless {
    True -> decode_treeless_literals_block(bytes, header, prev_tree)
    False -> decode_huffman_literals_block(bytes, header)
  }
}

fn decode_huffman_literals_block(
  bytes: BitArray,
  header: CompressedLiteralsHeader,
) -> Result(#(BitArray, BitArray, Option(huf.Tree)), error.CodecError) {
  // Slice the literals section payload out of the surrounding block
  // so the Huffman tree parser stops at the right boundary.
  let section_total = header.header_bytes + header.compressed_size
  use section <- result.try(slice_or_error(
    bytes,
    0,
    section_total,
    "zstd compressed literals section body",
  ))
  let assert Ok(after_section) =
    bit_array.slice(
      bytes,
      section_total,
      bit_array.byte_size(bytes) - section_total,
    )

  let assert Ok(tree_bytes) =
    bit_array.slice(
      section,
      header.header_bytes,
      section_total - header.header_bytes,
    )
  case huf.read_tree(tree_bytes) {
    Error(reason) -> Error(huf_error_to_codec(reason))
    Ok(#(tree, tree_consumed)) -> {
      let bitstream_size = header.compressed_size - tree_consumed
      use bitstream_bytes <- result.try(slice_or_error(
        section,
        header.header_bytes + tree_consumed,
        bitstream_size,
        "zstd Huffman literal bitstream",
      ))
      use literals <- result.try(decode_huffman_streams(
        tree,
        bitstream_bytes,
        header,
      ))
      Ok(#(literals, after_section, Some(tree)))
    }
  }
}

fn decode_treeless_literals_block(
  bytes: BitArray,
  header: CompressedLiteralsHeader,
  prev_tree: Option(huf.Tree),
) -> Result(#(BitArray, BitArray, Option(huf.Tree)), error.CodecError) {
  case prev_tree {
    None ->
      Error(error.CodecInvalidData(
        message: "zstd treeless literals without a prior Huffman tree",
      ))
    Some(tree) -> {
      let section_total = header.header_bytes + header.compressed_size
      use section <- result.try(slice_or_error(
        bytes,
        0,
        section_total,
        "zstd treeless literals section body",
      ))
      let assert Ok(after_section) =
        bit_array.slice(
          bytes,
          section_total,
          bit_array.byte_size(bytes) - section_total,
        )
      // Treeless literals omit the Huffman_Tree_Description so the
      // whole compressed_size is the bitstream payload.
      use bitstream_bytes <- result.try(slice_or_error(
        section,
        header.header_bytes,
        header.compressed_size,
        "zstd treeless literal bitstream",
      ))
      use literals <- result.try(decode_huffman_streams(
        tree,
        bitstream_bytes,
        header,
      ))
      Ok(#(literals, after_section, prev_tree))
    }
  }
}

fn decode_huffman_streams(
  tree: huf.Tree,
  bitstream_bytes: BitArray,
  header: CompressedLiteralsHeader,
) -> Result(BitArray, error.CodecError) {
  case header.streams {
    1 ->
      huf.decode_stream(tree, bitstream_bytes, header.regenerated_size)
      |> result.map_error(huf_error_to_codec)
    _ ->
      huf.decode_four_streams(tree, bitstream_bytes, header.regenerated_size)
      |> result.map_error(huf_error_to_codec)
  }
}

fn huf_error_to_codec(err: huf.HufError) -> error.CodecError {
  case err {
    huf.HufTruncated(message) -> error.CodecInvalidData(message: message)
    huf.HufInvalidWeights(message) -> error.CodecInvalidData(message: message)
    huf.HufBitstreamError(_) ->
      error.CodecInvalidData(message: "zstd Huffman bitstream truncated")
    huf.HufUnsupported(feature) -> error.CodecNotImplemented(feature: feature)
  }
}

fn parse_compressed_literals_header(
  bytes: BitArray,
  header_byte: Int,
  size_format: Int,
) -> Result(CompressedLiteralsHeader, error.CodecError) {
  case size_format {
    0 ->
      // 3-byte header, 1 stream, 10-bit regen and compressed sizes.
      case bytes {
        <<_, b1, b2, _:bytes>> -> {
          let high_bits_of_header_byte = int.bitwise_shift_right(header_byte, 4)
          let regenerated_size =
            int.bitwise_or(
              high_bits_of_header_byte,
              int.bitwise_shift_left(int.bitwise_and(b1, 0x3F), 4),
            )
          let compressed_size =
            int.bitwise_or(
              int.bitwise_shift_right(b1, 6),
              int.bitwise_shift_left(b2, 2),
            )
          Ok(CompressedLiteralsHeader(
            regenerated_size: regenerated_size,
            compressed_size: compressed_size,
            streams: 1,
            header_bytes: 3,
          ))
        }
        _ ->
          Error(error.CodecInvalidData(
            message: "truncated zstd compressed-literals 3-byte header",
          ))
      }
    1 ->
      // 3-byte header, 4 streams, 10-bit regen and compressed sizes.
      case bytes {
        <<_, b1, b2, _:bytes>> -> {
          let high_bits_of_header_byte = int.bitwise_shift_right(header_byte, 4)
          let regenerated_size =
            int.bitwise_or(
              high_bits_of_header_byte,
              int.bitwise_shift_left(int.bitwise_and(b1, 0x3F), 4),
            )
          let compressed_size =
            int.bitwise_or(
              int.bitwise_shift_right(b1, 6),
              int.bitwise_shift_left(b2, 2),
            )
          Ok(CompressedLiteralsHeader(
            regenerated_size: regenerated_size,
            compressed_size: compressed_size,
            streams: 4,
            header_bytes: 3,
          ))
        }
        _ ->
          Error(error.CodecInvalidData(
            message: "truncated zstd compressed-literals 3-byte header",
          ))
      }
    2 ->
      // 4-byte header, 4 streams, 14-bit regen and compressed sizes.
      case bytes {
        <<_, b1, b2, b3, _:bytes>> -> {
          let high_bits_of_header_byte = int.bitwise_shift_right(header_byte, 4)
          let regenerated_size =
            int.bitwise_or(
              high_bits_of_header_byte,
              int.bitwise_or(
                int.bitwise_shift_left(b1, 4),
                int.bitwise_shift_left(int.bitwise_and(b2, 0x3), 12),
              ),
            )
          let compressed_size =
            int.bitwise_or(
              int.bitwise_shift_right(b2, 2),
              int.bitwise_shift_left(b3, 6),
            )
          Ok(CompressedLiteralsHeader(
            regenerated_size: regenerated_size,
            compressed_size: compressed_size,
            streams: 4,
            header_bytes: 4,
          ))
        }
        _ ->
          Error(error.CodecInvalidData(
            message: "truncated zstd compressed-literals 4-byte header",
          ))
      }
    _ ->
      // size_format = 3: 5-byte header, 4 streams, 18-bit fields.
      case bytes {
        <<_, b1, b2, b3, b4, _:bytes>> -> {
          let high_bits_of_header_byte = int.bitwise_shift_right(header_byte, 4)
          let regenerated_size =
            int.bitwise_or(
              high_bits_of_header_byte,
              int.bitwise_or(
                int.bitwise_shift_left(b1, 4),
                int.bitwise_shift_left(int.bitwise_and(b2, 0x3F), 12),
              ),
            )
          let compressed_size =
            int.bitwise_or(
              int.bitwise_shift_right(b2, 6),
              int.bitwise_or(
                int.bitwise_shift_left(b3, 2),
                int.bitwise_shift_left(b4, 10),
              ),
            )
          Ok(CompressedLiteralsHeader(
            regenerated_size: regenerated_size,
            compressed_size: compressed_size,
            streams: 4,
            header_bytes: 5,
          ))
        }
        _ ->
          Error(error.CodecInvalidData(
            message: "truncated zstd compressed-literals 5-byte header",
          ))
      }
  }
}

fn parse_raw_or_rle_literals(
  bytes: BitArray,
  header_byte: Int,
  size_format: Int,
  is_rle: Bool,
) -> Result(#(BitArray, BitArray), error.CodecError) {
  case size_format {
    0 | 2 -> {
      // 1-byte header — size is bits 3..7 of the header byte.
      let regenerated_size = int.bitwise_shift_right(header_byte, 3)
      let assert Ok(after_header) =
        bit_array.slice(bytes, 1, bit_array.byte_size(bytes) - 1)
      finalize_literals(after_header, regenerated_size, is_rle)
    }
    1 -> {
      // 2-byte header — size spans bits 4..7 of byte 0 (low) and all
      // bits of byte 1 (high), little-endian wrt the spec.
      case bytes {
        <<_h, b1, _:bytes>> -> {
          let regenerated_size =
            int.bitwise_or(
              int.bitwise_shift_right(header_byte, 4),
              int.bitwise_shift_left(b1, 4),
            )
          let assert Ok(after_header) =
            bit_array.slice(bytes, 2, bit_array.byte_size(bytes) - 2)
          finalize_literals(after_header, regenerated_size, is_rle)
        }
        _ ->
          Error(error.CodecInvalidData(
            message: "truncated zstd literals 2-byte header",
          ))
      }
    }
    _ ->
      Error(error.CodecNotImplemented(
        feature: "zstd literals 3-byte header (size_format 3 for compressed)",
      ))
  }
}

fn finalize_literals(
  bytes: BitArray,
  size: Int,
  is_rle: Bool,
) -> Result(#(BitArray, BitArray), error.CodecError) {
  case is_rle {
    True ->
      case bytes {
        <<byte, rest:bytes>> -> Ok(#(zstd_repeat_byte(byte, size, <<>>), rest))
        _ ->
          Error(error.CodecInvalidData(message: "truncated zstd RLE literals"))
      }
    False -> {
      use chunk <- result.try(slice_or_error(
        bytes,
        0,
        size,
        "zstd raw literals body",
      ))
      let assert Ok(rest) =
        bit_array.slice(bytes, size, bit_array.byte_size(bytes) - size)
      Ok(#(chunk, rest))
    }
  }
}

fn zstd_repeat_byte(byte: Int, count: Int, acc: BitArray) -> BitArray {
  case count {
    0 -> acc
    _ -> zstd_repeat_byte(byte, count - 1, <<acc:bits, byte>>)
  }
}

// -- sequences section + sequence application -------------------------

fn parse_and_apply_sequences(
  bytes: BitArray,
  literals: BitArray,
  prev_tables: SeqTablesState,
) -> Result(#(BitArray, SeqTablesState), error.CodecError) {
  case bytes {
    <<>> -> Ok(#(literals, prev_tables))
    <<num_byte, _:bytes>> if num_byte == 0 -> Ok(#(literals, prev_tables))
    <<num_byte, _:bytes>> if num_byte < 128 ->
      parse_sequences(bytes, 1, num_byte, literals, prev_tables)
    <<num_byte, b1, _:bytes>> if num_byte < 255 -> {
      // RFC 8478 §3.1.1.3.2.1 / zstd_compression_format.md:
      //   Number_of_Sequences = ((byte0 - 0x80) << 8) + byte1
      // The 2-byte form FULLY OVERLAPS the 1-byte form (no extra
      // 0x80 offset on top), so a prior `+ 128` was double-counting
      // and produced ~2x the sequence count for any compressed
      // block that emitted more than 127 sequences.
      let n = { num_byte - 128 } * 256 + b1
      parse_sequences(bytes, 2, n, literals, prev_tables)
    }
    <<255, b1, b2, _:bytes>> -> {
      let n = b1 + b2 * 256 + 0x7F00
      parse_sequences(bytes, 3, n, literals, prev_tables)
    }
    _ ->
      Error(error.CodecInvalidData(message: "truncated zstd sequences header"))
  }
}

fn parse_sequences(
  bytes: BitArray,
  count_size: Int,
  num_sequences: Int,
  literals: BitArray,
  prev_tables: SeqTablesState,
) -> Result(#(BitArray, SeqTablesState), error.CodecError) {
  use after_count <- result.try(slice_after(
    bytes,
    count_size,
    "zstd sequences count",
  ))
  case after_count {
    <<modes, _:bytes>> -> {
      let literal_lengths_mode =
        int.bitwise_and(int.bitwise_shift_right(modes, 6), 0x3)
      let offsets_mode = int.bitwise_and(int.bitwise_shift_right(modes, 4), 0x3)
      let match_lengths_mode =
        int.bitwise_and(int.bitwise_shift_right(modes, 2), 0x3)
      let reserved = int.bitwise_and(modes, 0x3)
      use <- bool.guard(
        when: reserved != 0,
        return: Error(error.CodecInvalidData(
          message: "zstd sequences mode byte has reserved bits set",
        )),
      )
      use after_modes <- result.try(slice_after(
        after_count,
        1,
        "zstd sequences mode byte",
      ))
      use #(ll_table, ll_log, after_ll) <- result.try(load_sequence_table(
        after_modes,
        literal_lengths_mode,
        SeqAlphabetLl,
        prev_tables.ll,
      ))
      use #(of_table, of_log, after_of) <- result.try(load_sequence_table(
        after_ll,
        offsets_mode,
        SeqAlphabetOf,
        prev_tables.of,
      ))
      use #(ml_table, ml_log, bitstream) <- result.try(load_sequence_table(
        after_of,
        match_lengths_mode,
        SeqAlphabetMl,
        prev_tables.ml,
      ))
      use plain <- result.try(apply_sequences_with_tables(
        num_sequences,
        bitstream,
        literals,
        ll_table,
        ll_log,
        of_table,
        of_log,
        ml_table,
        ml_log,
      ))
      Ok(#(
        plain,
        SeqTablesState(
          ll: Some(#(ll_table, ll_log)),
          of: Some(#(of_table, of_log)),
          ml: Some(#(ml_table, ml_log)),
        ),
      ))
    }
    _ ->
      Error(error.CodecInvalidData(
        message: "truncated zstd sequences modes byte",
      ))
  }
}

/// Identifies which sequence alphabet a table description applies to.
/// Used to look up the correct predefined distribution, the maximum
/// allowed accuracy_log, and the maximum symbol value when parsing an
/// FSE_Compressed_Mode header.
type SeqAlphabet {
  SeqAlphabetLl
  SeqAlphabetOf
  SeqAlphabetMl
}

fn alphabet_max_log(alphabet: SeqAlphabet) -> Int {
  case alphabet {
    SeqAlphabetLl -> 9
    SeqAlphabetOf -> 8
    SeqAlphabetMl -> 9
  }
}

fn alphabet_max_symbol(alphabet: SeqAlphabet) -> Int {
  // The RFC 8478 sequence-symbol alphabets have upper bounds that
  // both bound the predefined distributions and cap any user-supplied
  // FSE distribution.
  case alphabet {
    SeqAlphabetLl -> 35
    SeqAlphabetOf -> 31
    SeqAlphabetMl -> 52
  }
}

fn predefined_for(
  alphabet: SeqAlphabet,
) -> #(dict.Dict(Int, fse.StateEntry), Int) {
  case alphabet {
    SeqAlphabetLl -> #(
      fse.predefined_literal_length_table(),
      fse.predefined_literal_length_log(),
    )
    SeqAlphabetOf -> #(
      fse.predefined_offset_table(),
      fse.predefined_offset_log(),
    )
    SeqAlphabetMl -> #(
      fse.predefined_match_length_table(),
      fse.predefined_match_length_log(),
    )
  }
}

fn alphabet_label(alphabet: SeqAlphabet) -> String {
  case alphabet {
    SeqAlphabetLl -> "literal_length"
    SeqAlphabetOf -> "offset"
    SeqAlphabetMl -> "match_length"
  }
}

/// Read the table description for one sequence alphabet, honouring the
/// Predefined / RLE / FSE_Compressed / Repeat selector encoded in the
/// modes byte.  Returns the materialised state table, its accuracy_log
/// (so the sequence decoder knows how many bits to read for the
/// initial state), and the byte slice that immediately follows the
/// table description.
fn load_sequence_table(
  bytes: BitArray,
  mode: Int,
  alphabet: SeqAlphabet,
  prev: Option(#(dict.Dict(Int, fse.StateEntry), Int)),
) -> Result(#(dict.Dict(Int, fse.StateEntry), Int, BitArray), error.CodecError) {
  case mode {
    0 -> {
      let #(table, accuracy_log) = predefined_for(alphabet)
      Ok(#(table, accuracy_log, bytes))
    }
    1 ->
      case bytes {
        <<symbol, rest:bytes>> -> {
          // RLE_Mode: the entire table maps state 0 to the single
          // symbol with zero baseline and zero nb_bits.  Accuracy_log
          // is 0 so the decoder reads no bits to seed the state.
          let table =
            dict.from_list([
              #(0, fse.StateEntry(symbol: symbol, nb_bits: 0, baseline: 0)),
            ])
          Ok(#(table, 0, rest))
        }
        _ ->
          Error(error.CodecInvalidData(
            message: "truncated zstd "
            <> alphabet_label(alphabet)
            <> " RLE mode symbol",
          ))
      }
    2 -> {
      use #(distribution, accuracy_log, rest) <- result.try(
        read_fse_distribution(
          bytes,
          alphabet_max_log(alphabet),
          alphabet_max_symbol(alphabet),
          alphabet_label(alphabet),
        ),
      )
      let table = fse.build_state_table(distribution, accuracy_log)
      Ok(#(table, accuracy_log, rest))
    }
    _ ->
      // Repeat_Mode: reuse the FSE table the previous block carried
      // for this alphabet.  RFC 8478 §3.1.1.4 forbids Repeat_Mode in
      // the first block of a frame, so an absent prior table is a
      // hard error.
      case prev {
        Some(#(table, accuracy_log)) -> Ok(#(table, accuracy_log, bytes))
        None ->
          Error(error.CodecInvalidData(
            message: "zstd "
            <> alphabet_label(alphabet)
            <> " Repeat_Mode without a prior FSE table",
          ))
      }
  }
}

fn apply_sequences_with_tables(
  num_sequences: Int,
  bitstream: BitArray,
  literals: BitArray,
  ll_table: dict.Dict(Int, fse.StateEntry),
  ll_log: Int,
  of_table: dict.Dict(Int, fse.StateEntry),
  of_log: Int,
  ml_table: dict.Dict(Int, fse.StateEntry),
  ml_log: Int,
) -> Result(BitArray, error.CodecError) {
  case fse.new_backward_reader(bitstream) {
    Error(_) ->
      Error(error.CodecInvalidData(
        message: "zstd sequences bitstream is empty or missing marker",
      ))
    Ok(reader) -> {
      // Read initial states: literal_length first, offset, then match_length
      use #(ll_state, reader) <- result.try(read_state_init(
        reader,
        ll_log,
        "literal_length",
      ))
      use #(of_state, reader) <- result.try(read_state_init(
        reader,
        of_log,
        "offset",
      ))
      use #(ml_state, reader) <- result.try(read_state_init(
        reader,
        ml_log,
        "match_length",
      ))
      let ctx =
        SeqContext(
          literals: literals,
          literal_pos: 0,
          output_rev: [],
          rep0: 1,
          rep1: 4,
          rep2: 8,
          ll_state: ll_state,
          of_state: of_state,
          ml_state: ml_state,
          ll_table: ll_table,
          of_table: of_table,
          ml_table: ml_table,
        )
      use ctx <- result.try(decode_sequence_loop(num_sequences, ctx, reader))
      Ok(append_remaining_literals(ctx))
    }
  }
}

type SeqContext {
  SeqContext(
    literals: BitArray,
    literal_pos: Int,
    output_rev: List(Int),
    rep0: Int,
    rep1: Int,
    rep2: Int,
    ll_state: Int,
    of_state: Int,
    ml_state: Int,
    ll_table: dict.Dict(Int, fse.StateEntry),
    of_table: dict.Dict(Int, fse.StateEntry),
    ml_table: dict.Dict(Int, fse.StateEntry),
  )
}

// -- FSE distribution decoder (RFC 8478 §4.1.1.2) ----------------------
//
// The distribution header is a forward-read bit stream encoded LSB-
// first inside its enclosing byte sequence.  The first 4 bits hold
// `Accuracy_Log - 5`; subsequent counts come from a variable-bit
// state-machine that adjusts its read width as the running total
// approaches the target table size.  Zero counts trigger a 2-bit RLE
// jump until a < 3 group terminates the run.  Once the distribution
// is exhausted the encoder pads the remaining bits in the trailing
// byte; the FSE sequences bitstream resumes at the next byte boundary.

type FwdBitReader {
  FwdBitReader(
    source: BitArray,
    buffer: Int,
    bits: Int,
    overflow: Bool,
    bits_consumed: Int,
  )
}

fn new_fwd_reader(bytes: BitArray) -> FwdBitReader {
  FwdBitReader(
    source: bytes,
    buffer: 0,
    bits: 0,
    overflow: False,
    bits_consumed: 0,
  )
}

fn fwd_refill(reader: FwdBitReader, needed: Int) -> FwdBitReader {
  case reader.bits >= needed || reader.overflow {
    True -> reader
    False ->
      case reader.source {
        <<b, rest:bytes>> ->
          fwd_refill(
            FwdBitReader(
              source: rest,
              buffer: int.bitwise_or(
                reader.buffer,
                int.bitwise_shift_left(b, reader.bits),
              ),
              bits: reader.bits + 8,
              overflow: False,
              bits_consumed: reader.bits_consumed,
            ),
            needed,
          )
        _ -> FwdBitReader(..reader, overflow: True)
      }
  }
}

fn fwd_peek(reader: FwdBitReader, count: Int) -> #(Int, FwdBitReader) {
  let reader = fwd_refill(reader, count)
  let mask = int.bitwise_shift_left(1, count) - 1
  #(int.bitwise_and(reader.buffer, mask), reader)
}

fn fwd_drop(reader: FwdBitReader, count: Int) -> FwdBitReader {
  let reader = fwd_refill(reader, count)
  FwdBitReader(
    source: reader.source,
    buffer: int.bitwise_shift_right(reader.buffer, count),
    bits: reader.bits - count,
    overflow: reader.overflow,
    bits_consumed: reader.bits_consumed + count,
  )
}

fn fwd_read(
  reader: FwdBitReader,
  count: Int,
  label: String,
) -> Result(#(Int, FwdBitReader), error.CodecError) {
  let reader = fwd_refill(reader, count)
  case reader.bits < count {
    True -> Error(error.CodecInvalidData(message: "truncated zstd " <> label))
    False -> {
      let #(value, reader) = fwd_peek(reader, count)
      Ok(#(value, fwd_drop(reader, count)))
    }
  }
}

fn read_fse_distribution(
  bytes: BitArray,
  max_accuracy_log: Int,
  max_symbol: Int,
  label: String,
) -> Result(#(List(Int), Int, BitArray), error.CodecError) {
  let reader = new_fwd_reader(bytes)
  use #(accuracy_minus_5, reader) <- result.try(fwd_read(
    reader,
    4,
    label <> " distribution accuracy_log",
  ))
  let accuracy_log = accuracy_minus_5 + 5
  use <- bool.guard(
    when: accuracy_log > max_accuracy_log,
    return: Error(error.CodecInvalidData(
      message: "zstd "
      <> label
      <> " FSE accuracy_log exceeds the alphabet's maximum",
    )),
  )
  let table_size = int.bitwise_shift_left(1, accuracy_log)
  use #(counts, reader) <- result.try(decode_fse_distribution(
    reader,
    accuracy_log,
    table_size + 1,
    table_size,
    accuracy_log + 1,
    False,
    0,
    max_symbol,
    [],
    label,
  ))
  // The trailing bits inside the current byte are padding; the next
  // byte starts the section after the table description.
  let bytes_consumed = { reader.bits_consumed + 7 } / 8
  let total = bit_array.byte_size(bytes)
  case bit_array.slice(bytes, bytes_consumed, total - bytes_consumed) {
    Ok(rest) ->
      Ok(#(pad_distribution(counts, max_symbol + 1), accuracy_log, rest))
    Error(_) ->
      Error(error.CodecInvalidData(
        message: "truncated zstd " <> label <> " FSE distribution tail",
      ))
  }
}

fn decode_fse_distribution(
  reader: FwdBitReader,
  _accuracy_log: Int,
  remaining: Int,
  threshold: Int,
  bit_count: Int,
  previous_is_zero: Bool,
  charnum: Int,
  max_symbol: Int,
  acc: List(Int),
  label: String,
) -> Result(#(List(Int), FwdBitReader), error.CodecError) {
  case remaining > 1 && charnum <= max_symbol {
    False -> Ok(#(list.reverse(acc), reader))
    True ->
      case previous_is_zero {
        True -> {
          use #(extra, reader) <- result.try(read_zero_rle(reader, label))
          let acc = prepend_zeros(extra, acc)
          decode_fse_distribution(
            reader,
            0,
            remaining,
            threshold,
            bit_count,
            False,
            charnum + extra,
            max_symbol,
            acc,
            label,
          )
        }
        False -> {
          let #(value, reader) = fwd_peek(reader, bit_count)
          let #(count, bits_consumed) =
            decode_count_bits(value, threshold, remaining, bit_count)
          let reader = fwd_drop(reader, bits_consumed)
          let probability = count - 1
          let abs_prob = case probability < 0 {
            True -> -probability
            False -> probability
          }
          let remaining = remaining - abs_prob
          let previous_is_zero = probability == 0
          let #(threshold, bit_count) =
            shrink_threshold(threshold, bit_count, remaining)
          decode_fse_distribution(
            reader,
            0,
            remaining,
            threshold,
            bit_count,
            previous_is_zero,
            charnum + 1,
            max_symbol,
            [probability, ..acc],
            label,
          )
        }
      }
  }
}

/// Split out of `decode_fse_distribution` so the dominant case (short
/// form) doesn't dominate the inner block's indentation budget.
fn decode_count_bits(
  value: Int,
  threshold: Int,
  remaining: Int,
  bit_count: Int,
) -> #(Int, Int) {
  let max_val = 2 * threshold - 1 - remaining
  case int.bitwise_and(value, threshold - 1) < max_val {
    True -> #(int.bitwise_and(value, threshold - 1), bit_count - 1)
    False -> {
      let raw = int.bitwise_and(value, 2 * threshold - 1)
      let adjusted = case raw >= threshold {
        True -> raw - max_val
        False -> raw
      }
      #(adjusted, bit_count)
    }
  }
}

fn read_zero_rle(
  reader: FwdBitReader,
  label: String,
) -> Result(#(Int, FwdBitReader), error.CodecError) {
  read_zero_rle_loop(reader, 0, label)
}

fn read_zero_rle_loop(
  reader: FwdBitReader,
  acc: Int,
  label: String,
) -> Result(#(Int, FwdBitReader), error.CodecError) {
  use #(value, reader) <- result.try(fwd_read(
    reader,
    2,
    label <> " FSE distribution zero-RLE flag",
  ))
  case value {
    3 -> read_zero_rle_loop(reader, acc + 3, label)
    n -> Ok(#(acc + n, reader))
  }
}

fn shrink_threshold(
  threshold: Int,
  bit_count: Int,
  remaining: Int,
) -> #(Int, Int) {
  case remaining < threshold {
    True -> shrink_threshold(threshold / 2, bit_count - 1, remaining)
    False -> #(threshold, bit_count)
  }
}

fn prepend_zeros(count: Int, acc: List(Int)) -> List(Int) {
  case count {
    n if n <= 0 -> acc
    _ -> prepend_zeros(count - 1, [0, ..acc])
  }
}

fn pad_distribution(counts: List(Int), target: Int) -> List(Int) {
  let current = list.length(counts)
  case current >= target {
    True -> counts
    False -> list.append(counts, list.repeat(0, target - current))
  }
}

fn read_state_init(
  reader: fse.BackwardReader,
  bits: Int,
  label: String,
) -> Result(#(Int, fse.BackwardReader), error.CodecError) {
  case fse.read_backward_bits(reader, bits) {
    Ok(#(v, r)) -> Ok(#(v, r))
    Error(_) ->
      Error(error.CodecInvalidData(
        message: "truncated zstd " <> label <> " initial state",
      ))
  }
}

fn decode_sequence_loop(
  remaining: Int,
  ctx: SeqContext,
  reader: fse.BackwardReader,
) -> Result(SeqContext, error.CodecError) {
  case remaining {
    0 -> Ok(ctx)
    _ -> {
      let ll_code = state_symbol(ctx.ll_table, ctx.ll_state)
      let of_code = state_symbol(ctx.of_table, ctx.of_state)
      let ml_code = state_symbol(ctx.ml_table, ctx.ml_state)

      use #(offset_value, reader) <- result.try(read_bits_for(
        reader,
        of_code,
        "offset extra",
      ))
      use #(match_extra, reader) <- result.try(read_bits_for(
        reader,
        fse.ml_extra_bits(ml_code),
        "match-length extra",
      ))
      use #(lit_extra, reader) <- result.try(read_bits_for(
        reader,
        fse.ll_extra_bits(ll_code),
        "literal-length extra",
      ))

      let literal_length = fse.ll_base(ll_code) + lit_extra
      let match_length = fse.ml_base(ml_code) + match_extra
      let raw_offset = int.bitwise_shift_left(1, of_code) + offset_value
      let #(actual_offset, ctx_after_offset) =
        resolve_offset(ctx, of_code, raw_offset, literal_length)

      // Copy literals and match into output_rev.
      use ctx_after_lit <- result.try(copy_literals(
        ctx_after_offset,
        literal_length,
      ))
      use ctx_after_match <- result.try(copy_match(
        ctx_after_lit,
        actual_offset,
        match_length,
      ))

      // Update states if not the last sequence.
      case remaining {
        1 -> Ok(ctx_after_match)
        _ -> {
          use #(reader, ll_state) <- result.try(update_state(
            reader,
            ctx.ll_table,
            ctx.ll_state,
            "literal_length",
          ))
          use #(reader, ml_state) <- result.try(update_state(
            reader,
            ctx.ml_table,
            ctx.ml_state,
            "match_length",
          ))
          use #(reader, of_state) <- result.try(update_state(
            reader,
            ctx.of_table,
            ctx.of_state,
            "offset",
          ))
          decode_sequence_loop(
            remaining - 1,
            SeqContext(
              ..ctx_after_match,
              ll_state: ll_state,
              ml_state: ml_state,
              of_state: of_state,
            ),
            reader,
          )
        }
      }
    }
  }
}

fn state_symbol(table: dict.Dict(Int, fse.StateEntry), state: Int) -> Int {
  case dict.get(table, state) {
    Ok(entry) -> entry.symbol
    Error(_) -> 0
  }
}

fn update_state(
  reader: fse.BackwardReader,
  table: dict.Dict(Int, fse.StateEntry),
  state: Int,
  label: String,
) -> Result(#(fse.BackwardReader, Int), error.CodecError) {
  let entry = case dict.get(table, state) {
    Ok(e) -> e
    Error(_) -> fse.StateEntry(symbol: 0, nb_bits: 0, baseline: 0)
  }
  case fse.read_backward_bits(reader, entry.nb_bits) {
    Ok(#(extra, r)) -> Ok(#(r, entry.baseline + extra))
    Error(_) ->
      Error(error.CodecInvalidData(
        message: "truncated zstd " <> label <> " state-update bits",
      ))
  }
}

fn read_bits_for(
  reader: fse.BackwardReader,
  count: Int,
  label: String,
) -> Result(#(Int, fse.BackwardReader), error.CodecError) {
  case fse.read_backward_bits(reader, count) {
    Ok(p) -> Ok(p)
    Error(_) ->
      Error(error.CodecInvalidData(message: "truncated zstd " <> label))
  }
}

fn resolve_offset(
  ctx: SeqContext,
  of_code: Int,
  raw_offset: Int,
  literal_length: Int,
) -> #(Int, SeqContext) {
  case of_code {
    0 ->
      case literal_length {
        0 -> {
          let actual = ctx.rep1
          #(actual, SeqContext(..ctx, rep0: ctx.rep1, rep1: ctx.rep0))
        }
        _ -> #(ctx.rep0, ctx)
      }
    _ -> {
      let actual = raw_offset - 3
      let new_offset = case literal_length {
        0 -> actual + 1
        _ -> actual
      }
      let final_offset = case new_offset {
        n if n <= 0 -> 1
        n -> n
      }
      #(
        final_offset,
        SeqContext(..ctx, rep2: ctx.rep1, rep1: ctx.rep0, rep0: final_offset),
      )
    }
  }
}

fn copy_literals(
  ctx: SeqContext,
  count: Int,
) -> Result(SeqContext, error.CodecError) {
  case count {
    0 -> Ok(ctx)
    _ -> {
      case bit_array.slice(ctx.literals, ctx.literal_pos, count) {
        Ok(chunk) ->
          Ok(
            SeqContext(
              ..ctx,
              literal_pos: ctx.literal_pos + count,
              output_rev: prepend_bytes(chunk, ctx.output_rev),
            ),
          )
        Error(_) ->
          Error(error.CodecInvalidData(
            message: "zstd literal copy exceeds literals section",
          ))
      }
    }
  }
}

fn copy_match(
  ctx: SeqContext,
  offset: Int,
  length: Int,
) -> Result(SeqContext, error.CodecError) {
  copy_match_loop(ctx, offset, length)
}

fn copy_match_loop(
  ctx: SeqContext,
  offset: Int,
  remaining: Int,
) -> Result(SeqContext, error.CodecError) {
  case remaining {
    0 -> Ok(ctx)
    _ -> {
      case nth_from_back(ctx.output_rev, offset - 1) {
        Ok(byte) ->
          copy_match_loop(
            SeqContext(..ctx, output_rev: [byte, ..ctx.output_rev]),
            offset,
            remaining - 1,
          )
        Error(_) ->
          Error(error.CodecInvalidData(
            message: "zstd match offset exceeds emitted output",
          ))
      }
    }
  }
}

fn nth_from_back(values: List(Int), n: Int) -> Result(Int, Nil) {
  case values, n {
    [head, ..], 0 -> Ok(head)
    [_, ..rest], _ -> nth_from_back(rest, n - 1)
    [], _ -> Error(Nil)
  }
}

fn prepend_bytes(chunk: BitArray, acc: List(Int)) -> List(Int) {
  case chunk {
    <<b, rest:bytes>> -> prepend_bytes(rest, [b, ..acc])
    _ -> acc
  }
}

fn append_remaining_literals(ctx: SeqContext) -> BitArray {
  let remaining = bit_array.byte_size(ctx.literals) - ctx.literal_pos
  let assert Ok(tail) =
    bit_array.slice(ctx.literals, ctx.literal_pos, remaining)
  let prefix = reverse_list_to_bit_array(ctx.output_rev, <<>>)
  bit_array.concat([prefix, tail])
}

fn reverse_list_to_bit_array(values: List(Int), acc: BitArray) -> BitArray {
  case values {
    [] -> acc
    [head, ..rest] -> reverse_list_to_bit_array(rest, <<head, acc:bits>>)
  }
}

fn slice_or_error(
  bytes: BitArray,
  offset: Int,
  length: Int,
  label: String,
) -> Result(BitArray, error.CodecError) {
  case bit_array.slice(bytes, offset, length) {
    Ok(v) -> Ok(v)
    Error(_) -> Error(error.CodecInvalidData(message: "truncated " <> label))
  }
}

fn slice_after(
  bytes: BitArray,
  offset: Int,
  label: String,
) -> Result(BitArray, error.CodecError) {
  case bit_array.slice(bytes, offset, bit_array.byte_size(bytes) - offset) {
    Ok(v) -> Ok(v)
    Error(_) -> Error(error.CodecInvalidData(message: "truncated " <> label))
  }
}

fn decode_raw_block(
  bytes: BitArray,
  block_size: Int,
) -> Result(#(BitArray, BitArray), error.CodecError) {
  case bit_array.slice(bytes, 0, block_size) {
    Ok(chunk) ->
      case
        bit_array.slice(
          bytes,
          block_size,
          bit_array.byte_size(bytes) - block_size,
        )
      {
        Ok(rest) -> Ok(#(chunk, rest))
        Error(_) ->
          Error(error.CodecInvalidData(message: "truncated zstd raw block tail"))
      }
    Error(_) ->
      Error(error.CodecInvalidData(message: "truncated zstd raw block"))
  }
}

fn decode_rle_block(
  bytes: BitArray,
  block_size: Int,
) -> Result(#(BitArray, BitArray), error.CodecError) {
  case bytes {
    <<byte, rest:bytes>> -> Ok(#(repeat_byte(byte, block_size, <<>>), rest))
    _ -> Error(error.CodecInvalidData(message: "truncated zstd RLE block"))
  }
}

fn repeat_byte(byte: Int, count: Int, acc: BitArray) -> BitArray {
  case count {
    0 -> acc
    _ -> repeat_byte(byte, count - 1, <<acc:bits, byte>>)
  }
}

// -- helpers -----------------------------------------------------------

fn drop_bytes(
  bytes: BitArray,
  count: Int,
  label: String,
) -> Result(BitArray, error.CodecError) {
  case count {
    0 -> Ok(bytes)
    _ ->
      case bit_array.slice(bytes, count, bit_array.byte_size(bytes) - count) {
        Ok(rest) -> Ok(rest)
        Error(_) ->
          Error(error.CodecInvalidData(message: "truncated " <> label))
      }
  }
}

fn append_with_limit(
  output: BitArray,
  chunk: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  let projected = bit_array.byte_size(output) + bit_array.byte_size(chunk)
  case projected > limit.max_output_bytes(limits) {
    True ->
      Error(error.CodecLimitExceeded(
        limit: "max_output_bytes",
        actual: projected,
      ))
    False -> Ok(bit_array.concat([output, chunk]))
  }
}
