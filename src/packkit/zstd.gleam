//// Zstandard codec — pure-Gleam decoder.
////
//// The module parses the Zstandard frame envelope (magic, frame
//// header descriptor, window descriptor, optional dictionary id,
//// optional frame content size, optional trailing content checksum)
//// and walks the block stream.  Raw and RLE blocks decode directly;
//// compressed blocks (type 2) decode through the predefined FSE
//// tables in `packkit/internal/fse` when the literals section is in
//// Raw or RLE mode.  Huffman-compressed literals and non-predefined
//// FSE compression modes still return `CodecNotImplemented` for now.

import gleam/bit_array
import gleam/bool
import gleam/dict
import gleam/int
import gleam/result
import packkit/codec as codecs
import packkit/error
import packkit/internal/fse
import packkit/limit

const magic: Int = 0xFD2FB528

/// Zstandard codec smart constructor.
pub fn codec() -> codecs.Codec {
  codecs.zstd()
}

const max_block_size: Int = 0x20_000

/// Encode `bytes` as a Zstandard frame.  The encoder always emits raw
/// blocks (no compression, no checksum) — the output is a valid
/// Zstandard frame that any conforming decoder can read, but it
/// preserves the original byte count rather than shrinking it.  A
/// compression-aware encoder is intentionally future work.
pub fn encode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  let size = bit_array.byte_size(bytes)
  let header = build_zstd_frame_header(size)
  let blocks = build_raw_blocks(bytes, size)
  Ok(bit_array.concat([header, blocks]))
}

fn build_zstd_frame_header(size: Int) -> BitArray {
  // Single_Segment_flag = 1, no Window_Descriptor, no Dictionary_ID,
  // no Content_Checksum.  FCS encoding follows the size — 1 byte for
  // < 256, 2 bytes (FCS_flag = 1) for the 256..65535 range, 4 bytes
  // (FCS_flag = 2) for the 65536..(2^32)-1 range, otherwise 8 bytes
  // (FCS_flag = 3).
  case size {
    n if n < 256 -> <<0x28, 0xB5, 0x2F, 0xFD, 0x20, n>>
    n if n < 0x1_0000 -> <<
      0x28,
      0xB5,
      0x2F,
      0xFD,
      0x60,
      { n - 256 }:size(16)-little,
    >>
    n if n < 0x1_0000_0000 -> <<
      0x28,
      0xB5,
      0x2F,
      0xFD,
      0xA0,
      n:size(32)-little,
    >>
    n -> <<
      0x28,
      0xB5,
      0x2F,
      0xFD,
      0xE0,
      n:size(32)-little,
      0:size(32)-little,
    >>
  }
}

fn build_raw_blocks(bytes: BitArray, total: Int) -> BitArray {
  case total {
    0 -> raw_block_header(0, True)
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
      let block_header = raw_block_header(chunk_size, is_last)
      emit_raw_blocks_loop(
        rest,
        remaining_size - chunk_size,
        bit_array.concat([acc, block_header, chunk]),
      )
    }
  }
}

fn raw_block_header(block_size: Int, is_last: Bool) -> BitArray {
  let last_bit = case is_last {
    True -> 1
    False -> 0
  }
  let block_header_value =
    int.bitwise_or(int.bitwise_shift_left(block_size, 3), last_bit)
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

/// Decode a Zstandard frame using explicit limits.
pub fn decode_with_limits(
  bytes bytes: BitArray,
  limits limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  use <- bool.guard(
    when: bit_array.byte_size(bytes) > limit.max_input_bytes(limits),
    return: Error(error.CodecLimitExceeded(
      limit: "max_input_bytes",
      value: bit_array.byte_size(bytes),
    )),
  )

  use #(checksum_flag, rest) <- result.try(parse_frame_header(bytes))
  use #(output, rest) <- result.try(decode_blocks(rest, <<>>, limits))
  use _ <- result.try(consume_checksum(rest, checksum_flag))
  Ok(output)
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

fn decode_blocks(
  bytes: BitArray,
  output: BitArray,
  limits: limit.Limits,
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
      use #(plain, rest) <- result.try(decode_one_block(
        rest,
        block_type,
        block_size,
      ))
      use new_output <- result.try(append_with_limit(output, plain, limits))
      case last {
        True -> Ok(#(new_output, rest))
        False -> decode_blocks(rest, new_output, limits)
      }
    }
    _ -> Error(error.CodecInvalidData(message: "truncated zstd block header"))
  }
}

fn decode_one_block(
  bytes: BitArray,
  block_type: Int,
  block_size: Int,
) -> Result(#(BitArray, BitArray), error.CodecError) {
  case block_type {
    0 -> decode_raw_block(bytes, block_size)
    1 -> decode_rle_block(bytes, block_size)
    2 -> decode_compressed_block(bytes, block_size)
    _ -> Error(error.CodecInvalidData(message: "zstd reserved block type 3"))
  }
}

// -- compressed block --------------------------------------------------

fn decode_compressed_block(
  bytes: BitArray,
  block_size: Int,
) -> Result(#(BitArray, BitArray), error.CodecError) {
  use payload <- result.try(slice_or_error(
    bytes,
    0,
    block_size,
    "zstd compressed block payload",
  ))
  let assert Ok(rest) =
    bit_array.slice(bytes, block_size, bit_array.byte_size(bytes) - block_size)

  use #(literals, after_literals) <- result.try(parse_literals_section(payload))
  use plain <- result.try(parse_and_apply_sequences(after_literals, literals))
  Ok(#(plain, rest))
}

// -- literals section --------------------------------------------------

fn parse_literals_section(
  bytes: BitArray,
) -> Result(#(BitArray, BitArray), error.CodecError) {
  case bytes {
    <<header_byte, _:bytes>> -> {
      let literals_block_type = int.bitwise_and(header_byte, 0x3)
      let size_format =
        int.bitwise_and(int.bitwise_shift_right(header_byte, 2), 0x3)
      case literals_block_type {
        0 -> parse_raw_or_rle_literals(bytes, header_byte, size_format, False)
        1 -> parse_raw_or_rle_literals(bytes, header_byte, size_format, True)
        2 ->
          Error(error.CodecNotImplemented(
            feature: "zstd compressed (Huffman) literals",
          ))
        _ -> Error(error.CodecNotImplemented(feature: "zstd treeless literals"))
      }
    }
    _ ->
      Error(error.CodecInvalidData(message: "truncated zstd literals header"))
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
) -> Result(BitArray, error.CodecError) {
  case bytes {
    <<>> -> Ok(literals)
    <<num_byte, _:bytes>> if num_byte == 0 -> Ok(literals)
    <<num_byte, _:bytes>> if num_byte < 128 ->
      parse_sequences(bytes, 1, num_byte, literals)
    <<num_byte, b1, _:bytes>> if num_byte < 255 -> {
      let n = { num_byte - 128 } * 256 + b1 + 128
      parse_sequences(bytes, 2, n, literals)
    }
    <<255, b1, b2, _:bytes>> -> {
      let n = b1 + b2 * 256 + 0x7F00
      parse_sequences(bytes, 3, n, literals)
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
) -> Result(BitArray, error.CodecError) {
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
      use <- bool.guard(
        when: literal_lengths_mode != 0
          || offsets_mode != 0
          || match_lengths_mode != 0,
        return: Error(error.CodecNotImplemented(
          feature: "zstd non-predefined FSE compression modes",
        )),
      )
      let assert Ok(bitstream) =
        bit_array.slice(after_count, 1, bit_array.byte_size(after_count) - 1)
      apply_sequences_with_predefined(num_sequences, bitstream, literals)
    }
    _ ->
      Error(error.CodecInvalidData(
        message: "truncated zstd sequences modes byte",
      ))
  }
}

fn apply_sequences_with_predefined(
  num_sequences: Int,
  bitstream: BitArray,
  literals: BitArray,
) -> Result(BitArray, error.CodecError) {
  let ll_table = fse.predefined_literal_length_table()
  let ml_table = fse.predefined_match_length_table()
  let of_table = fse.predefined_offset_table()
  case fse.new_backward_reader(bitstream) {
    Error(_) ->
      Error(error.CodecInvalidData(
        message: "zstd sequences bitstream is empty or missing marker",
      ))
    Ok(reader) -> {
      // Read initial states: literal_length first, offset, then match_length
      use #(ll_state, reader) <- result.try(read_state_init(
        reader,
        fse.predefined_literal_length_log(),
        "literal_length",
      ))
      use #(of_state, reader) <- result.try(read_state_init(
        reader,
        fse.predefined_offset_log(),
        "offset",
      ))
      use #(ml_state, reader) <- result.try(read_state_init(
        reader,
        fse.predefined_match_length_log(),
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

// -- trailing content checksum -----------------------------------------

fn consume_checksum(
  bytes: BitArray,
  checksum_flag: Bool,
) -> Result(Nil, error.CodecError) {
  case checksum_flag {
    False -> Ok(Nil)
    True ->
      case bit_array.byte_size(bytes) {
        4 -> Ok(Nil)
        // The 4-byte checksum is consumed but not verified — xxHash64
        // is not yet implemented in pure Gleam.  Future work can read
        // the value and confirm it against an xxh64 of the decoded
        // bytes.
        n if n < 4 ->
          Error(error.CodecInvalidData(
            message: "zstd content checksum is shorter than 4 bytes",
          ))
        _ ->
          Error(error.CodecInvalidData(
            message: "zstd frame has trailing bytes after checksum",
          ))
      }
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
        value: projected,
      ))
    False -> Ok(bit_array.concat([output, chunk]))
  }
}
