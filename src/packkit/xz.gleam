//// xz codec — decoder for `.xz` streams.
////
//// The decoder validates the xz magic, parses stream and block
//// headers, walks the LZMA2 chunk sequence (uncompressed and
//// LZMA-compressed chunks), validates the index plus stream footer,
//// and emits the concatenated block payloads.  The LZMA range coder
//// itself lives in `packkit/internal/lzma`.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/result
import packkit/checksum
import packkit/codec as codecs
import packkit/error
import packkit/internal/bcj
import packkit/internal/lzma
import packkit/limit

const stream_footer_size: Int = 12

/// xz codec smart constructor.
pub fn codec() -> codecs.Codec {
  codecs.xz()
}

/// Encode `bytes` as an xz stream.  The encoder always emits a single
/// block with an LZMA2 filter chain that contains only uncompressed
/// chunks — every conforming xz decoder accepts the output, but the
/// payload is preserved verbatim rather than compressed.  A
/// compression-aware encoder (LZMA range coder) is intentionally future
/// work.
pub fn encode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  let size = bit_array.byte_size(bytes)
  let stream_header = encode_stream_header()
  let lzma2_payload = encode_lzma2_uncompressed(bytes, size)
  let block_header =
    encode_block_header(bit_array.byte_size(lzma2_payload), size)
  let block_check = <<checksum.crc32(bytes):size(32)-little>>
  let block_body = bit_array.concat([block_header, lzma2_payload])
  let block_padding =
    pad_zero_bytes(padding_to_align(bit_array.byte_size(block_body), 4))
  let block_full = bit_array.concat([block_body, block_padding, block_check])
  let unpadded =
    bit_array.byte_size(block_header)
    + bit_array.byte_size(lzma2_payload)
    + bit_array.byte_size(block_check)
  let index = encode_index(unpadded, size)
  let footer = encode_stream_footer(bit_array.byte_size(index))
  Ok(bit_array.concat([stream_header, block_full, index, footer]))
}

fn encode_stream_header() -> BitArray {
  // Magic + Stream Flags + CRC32(flags).  Flags = 0x00 0x01 (CRC32 check).
  let flags = <<0x00, 0x01>>
  let crc = checksum.crc32(flags)
  bit_array.concat([
    <<0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00>>,
    flags,
    <<crc:size(32)-little>>,
  ])
}

fn encode_block_header(compressed_size: Int, uncompressed_size: Int) -> BitArray {
  // Block_Flags = 0xC0: 1 filter, both sizes present.  Compressed size
  // = `compressed_size` (the LZMA2 byte stream we just emitted).
  // Filter: LZMA2 (id 0x21) with a 1-byte properties value of 0x16
  // (matches what `xz -c` emits).
  let comp_vi = encode_varint(compressed_size)
  let pre_pad =
    bit_array.concat([
      <<0xC0>>,
      comp_vi,
      encode_varint(uncompressed_size),
      <<0x21, 0x01, 0x16>>,
    ])
  let body_len_no_size_byte = bit_array.byte_size(pre_pad) + 1
  // header_size_minus_crc is body_len + 1 for the size byte itself.
  // Total header size must be a multiple of 4.
  let total_no_pad = body_len_no_size_byte + 4
  let total_size = round_up_to_4(total_no_pad)
  let header_size_byte = total_size / 4 - 1
  let padding = pad_zero_bytes(total_size - total_no_pad)
  let body_with_size =
    bit_array.concat([<<header_size_byte>>, pre_pad, padding])
  let crc = checksum.crc32(body_with_size)
  bit_array.concat([body_with_size, <<crc:size(32)-little>>])
}

fn encode_lzma2_uncompressed(bytes: BitArray, size: Int) -> BitArray {
  case size {
    0 -> <<0x00>>
    _ -> emit_uncompressed_chunks(bytes, size, <<>>)
  }
}

const lzma2_uncompressed_chunk_max: Int = 0x1_0000

fn emit_uncompressed_chunks(
  remaining: BitArray,
  remaining_size: Int,
  acc: BitArray,
) -> BitArray {
  case remaining_size {
    0 -> bit_array.concat([acc, <<0x00>>])
    n -> {
      let chunk = case n > lzma2_uncompressed_chunk_max {
        True -> lzma2_uncompressed_chunk_max
        False -> n
      }
      let assert Ok(payload) = bit_array.slice(remaining, 0, chunk)
      let assert Ok(rest) =
        bit_array.slice(
          remaining,
          chunk,
          bit_array.byte_size(remaining) - chunk,
        )
      let size_minus_1 = chunk - 1
      let header = <<
        0x01,
        int.bitwise_and(int.bitwise_shift_right(size_minus_1, 8), 0xFF),
        int.bitwise_and(size_minus_1, 0xFF),
      >>
      emit_uncompressed_chunks(
        rest,
        remaining_size - chunk,
        bit_array.concat([acc, header, payload]),
      )
    }
  }
}

fn encode_index(unpadded_size: Int, uncompressed_size: Int) -> BitArray {
  let body =
    bit_array.concat([
      <<0x00, 0x01>>,
      encode_varint(unpadded_size),
      encode_varint(uncompressed_size),
    ])
  let body_with_padding =
    bit_array.concat([
      body,
      pad_zero_bytes(padding_to_align(bit_array.byte_size(body), 4)),
    ])
  let crc = checksum.crc32(body_with_padding)
  bit_array.concat([body_with_padding, <<crc:size(32)-little>>])
}

fn encode_stream_footer(index_size: Int) -> BitArray {
  let backward = index_size / 4 - 1
  let flags = <<0x00, 0x01>>
  let crc = checksum.crc32(<<backward:size(32)-little, flags:bits>>)
  bit_array.concat([
    <<crc:size(32)-little, backward:size(32)-little>>,
    flags,
    <<0x59, 0x5A>>,
  ])
}

fn encode_varint(value: Int) -> BitArray {
  case value < 0x80 {
    True -> <<value>>
    False -> {
      let byte = int.bitwise_or(int.bitwise_and(value, 0x7F), 0x80)
      bit_array.concat([
        <<byte>>,
        encode_varint(int.bitwise_shift_right(value, 7)),
      ])
    }
  }
}

fn pad_zero_bytes(count: Int) -> BitArray {
  case count {
    0 -> <<>>
    _ -> bit_array.concat([<<0>>, pad_zero_bytes(count - 1)])
  }
}

fn round_up_to_4(value: Int) -> Int {
  case value % 4 {
    0 -> value
    n -> value + 4 - n
  }
}

/// Decode an xz stream using default limits.
pub fn decode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  decode_with_limits(bytes: bytes, limits: limit.default())
}

/// Decode an xz stream using explicit limits.
///
/// Handles multi-stream files (per `xz-file-format.txt` §1: a `.xz`
/// file is a concatenation of one or more independent streams, each
/// optionally followed by stream padding aligned to 4 bytes).  The
/// concatenated payloads are returned as a single `BitArray`.
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

  decode_streams_loop(bytes, <<>>, 0, limits)
}

fn decode_streams_loop(
  bytes: BitArray,
  acc: BitArray,
  accumulated_size: Int,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  use #(header_flags, rest) <- result.try(parse_stream_header(bytes))
  use #(payload, rest) <- result.try(decode_blocks(
    rest,
    header_flags,
    <<>>,
    [],
    limits,
  ))
  let next_size = accumulated_size + bit_array.byte_size(payload)
  case next_size > limit.max_output_bytes(limits) {
    True ->
      Error(error.CodecLimitExceeded(
        limit: "max_output_bytes",
        actual: next_size,
      ))
    False -> {
      let acc = bit_array.concat([acc, payload])
      let rest = skip_stream_padding(rest)
      case bit_array.byte_size(rest) {
        0 -> Ok(acc)
        _ -> decode_streams_loop(rest, acc, next_size, limits)
      }
    }
  }
}

/// Inter-stream padding is 0x00 bytes, always a multiple of 4.  Per
/// the spec, the bytes between two streams must all be zero and the
/// total count must be divisible by 4; we drop them so the next
/// header parse starts at the right offset.
fn skip_stream_padding(bytes: BitArray) -> BitArray {
  case bytes {
    <<0x00, 0x00, 0x00, 0x00, rest:bytes>> -> skip_stream_padding(rest)
    _ -> bytes
  }
}

// -- stream header -------------------------------------------------------

fn parse_stream_header(
  bytes: BitArray,
) -> Result(#(Int, BitArray), error.CodecError) {
  case bytes {
    <<
      0xFD,
      0x37,
      0x7A,
      0x58,
      0x5A,
      0x00,
      flag_zero,
      check_type,
      crc:bytes-size(4),
      rest:bytes,
    >> -> {
      use <- bool.guard(
        when: flag_zero != 0,
        return: Error(error.CodecInvalidData(
          message: "xz stream header reserved byte is non-zero",
        )),
      )
      let expected = checksum.crc32(<<flag_zero, check_type>>)
      use <- bool.guard(
        when: expected != bit_array_to_u32_le(crc),
        return: Error(error.CodecInvalidData(
          message: "xz stream header CRC mismatch",
        )),
      )
      Ok(#(check_type, rest))
    }
    _ -> Error(error.CodecInvalidData(message: "invalid xz stream header"))
  }
}

fn bit_array_to_u32_le(bytes: BitArray) -> Int {
  case bytes {
    <<value:little-unsigned-size(32)>> -> value
    _ -> 0
  }
}

// -- block / index dispatch ---------------------------------------------

fn decode_blocks(
  bytes: BitArray,
  check_type: Int,
  output: BitArray,
  records_acc: List(#(Int, Int)),
  limits: limit.Limits,
) -> Result(#(BitArray, BitArray), error.CodecError) {
  case bytes {
    <<0x00, rest:bytes>> ->
      // Index indicator.  Validate the index and footer, then return.
      finalize_stream(rest, check_type, output, list.reverse(records_acc))
    <<_first, _:bytes>> -> {
      use #(plain, unpadded, uncompressed, rest) <- result.try(decode_block(
        bytes,
        check_type,
        limits,
      ))
      use new_output <- result.try(append_with_limit(output, plain, limits))
      decode_blocks(
        rest,
        check_type,
        new_output,
        [#(unpadded, uncompressed), ..records_acc],
        limits,
      )
    }
    _ ->
      Error(error.CodecInvalidData(
        message: "truncated xz stream before block or index",
      ))
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

// -- block --------------------------------------------------------------

fn decode_block(
  bytes: BitArray,
  check_type: Int,
  limits: limit.Limits,
) -> Result(#(BitArray, Int, Int, BitArray), error.CodecError) {
  case bytes {
    <<size_byte, _:bytes>> -> {
      let header_size = { size_byte + 1 } * 4
      case bit_array.slice(bytes, 0, header_size) {
        Error(_) ->
          Error(error.CodecInvalidData(message: "truncated xz block header"))
        Ok(header_chunk) -> {
          use #(flags, comp_size, uncomp_size, filters, _padding) <- result.try(
            parse_block_header(header_chunk, header_size),
          )
          // Multi-filter chains are supported when:
          //   - the final filter is LZMA2 (the spec requires the
          //     last filter to be the compression filter),
          //   - every earlier filter is a recognised pre-processor.
          // After LZMA2 decode the pre-processors are applied to
          // the output in REVERSE order, since each pre-processor's
          // encode pass ran before LZMA2 saw the bytes.
          use #(lzma2_props, pre_filters) <- result.try(split_filter_chain(
            filters,
          ))
          let _ = flags
          // Slice the compressed data immediately after the header.
          let payload_offset = header_size
          let payload_size = case comp_size {
            CompressedKnown(v) -> v
            CompressedUnknown -> 0
          }
          use payload <- result.try(slice_required(
            bytes,
            payload_offset,
            payload_size,
            "xz block data",
          ))
          use lzma_out <- result.try(decode_lzma2(payload, lzma2_props, limits))
          use plain <- result.try(apply_pre_filters_reverse(
            lzma_out,
            pre_filters,
          ))
          use <- bool.guard(
            when: case uncomp_size {
              UncompressedKnown(v) -> bit_array.byte_size(plain) != v
              UncompressedUnknown -> False
            },
            return: Error(error.CodecInvalidData(
              message: "xz block uncompressed size mismatch",
            )),
          )
          // Block padding aligns to 4 bytes.
          let used = payload_offset + payload_size
          let pad = padding_to_align(used, 4)
          let after_padding = payload_offset + payload_size + pad
          use <- bool.guard(
            when: pad > 0
              && !slice_is_zero(bytes, payload_offset + payload_size, pad),
            return: Error(error.CodecInvalidData(
              message: "xz block padding has non-zero bytes",
            )),
          )
          let check_size = check_size_for(check_type)
          use check_bytes <- result.try(slice_required(
            bytes,
            after_padding,
            check_size,
            "xz block check",
          ))
          use _ <- result.try(verify_block_check(plain, check_type, check_bytes))
          let total_block = after_padding + check_size
          let unpadded = header_size + payload_size + check_size
          let assert Ok(rest) =
            bit_array.slice(
              bytes,
              total_block,
              bit_array.byte_size(bytes) - total_block,
            )
          Ok(#(plain, unpadded, bit_array.byte_size(plain), rest))
        }
      }
    }
    _ -> Error(error.CodecInvalidData(message: "truncated xz block header"))
  }
}

type SizeField {
  CompressedKnown(value: Int)
  CompressedUnknown
}

type UncompressedField {
  UncompressedKnown(value: Int)
  UncompressedUnknown
}

fn parse_block_header(
  header: BitArray,
  size: Int,
) -> Result(
  #(Int, SizeField, UncompressedField, List(#(Int, Int)), BitArray),
  error.CodecError,
) {
  // header[0] is size byte, header[size-4..size-1] is CRC32 over header[0..size-5]
  use <- bool.guard(
    when: size < 8,
    return: Error(error.CodecInvalidData(message: "xz block header too small")),
  )
  let crc_offset = size - 4
  use header_no_crc <- result.try(slice_required(
    header,
    0,
    crc_offset,
    "xz block header pre-CRC",
  ))
  use crc_bytes <- result.try(slice_required(
    header,
    crc_offset,
    4,
    "xz block header CRC",
  ))
  let expected = checksum.crc32(header_no_crc)
  use <- bool.guard(
    when: expected != bit_array_to_u32_le(crc_bytes),
    return: Error(error.CodecInvalidData(
      message: "xz block header CRC mismatch",
    )),
  )

  // Skip the size byte we already consumed for header_size; parse flags next.
  let assert Ok(after_size) = bit_array.slice(header_no_crc, 1, crc_offset - 1)
  case after_size {
    <<flags, rest:bytes>> -> {
      let filter_count = int.bitwise_and(flags, 0x03) + 1
      let has_comp_size = int.bitwise_and(flags, 0x40) != 0
      let has_uncomp_size = int.bitwise_and(flags, 0x80) != 0
      let reserved_bits = int.bitwise_and(flags, 0x3C)
      use <- bool.guard(
        when: reserved_bits != 0,
        return: Error(error.CodecInvalidData(
          message: "xz block header has reserved bits set",
        )),
      )
      use #(comp_size, rest) <- result.try(case has_comp_size {
        True -> {
          use #(value, rest) <- result.try(read_varint(rest))
          Ok(#(CompressedKnown(value), rest))
        }
        False -> Ok(#(CompressedUnknown, rest))
      })
      use #(uncomp_size, rest) <- result.try(case has_uncomp_size {
        True -> {
          use #(value, rest) <- result.try(read_varint(rest))
          Ok(#(UncompressedKnown(value), rest))
        }
        False -> Ok(#(UncompressedUnknown, rest))
      })
      use #(filters, rest) <- result.try(parse_filters(rest, filter_count, []))
      Ok(#(flags, comp_size, uncomp_size, filters, rest))
    }
    _ -> Error(error.CodecInvalidData(message: "xz block header missing flags"))
  }
}

fn parse_filters(
  bytes: BitArray,
  remaining: Int,
  acc: List(#(Int, Int)),
) -> Result(#(List(#(Int, Int)), BitArray), error.CodecError) {
  case remaining {
    0 -> Ok(#(list.reverse(acc), bytes))
    _ -> {
      use #(filter_id, bytes) <- result.try(read_varint(bytes))
      use #(props_size, bytes) <- result.try(read_varint(bytes))
      use _props_bytes <- result.try(slice_required(
        bytes,
        0,
        props_size,
        "xz filter properties",
      ))
      let assert Ok(rest) =
        bit_array.slice(
          bytes,
          props_size,
          bit_array.byte_size(bytes) - props_size,
        )
      let props_int = case props_size {
        1 -> {
          let assert <<v, _:bytes>> = bytes
          v
        }
        _ -> 0
      }
      parse_filters(rest, remaining - 1, [#(filter_id, props_int), ..acc])
    }
  }
}

// -- filter chain -------------------------------------------------------

/// XZ blocks always terminate with the compression filter (LZMA2,
/// id 0x21).  Any earlier filters in the chain are pre-processors
/// that ran before LZMA2 saw the bytes; the decoder must apply
/// their inverse to LZMA2's output in REVERSE chain order.  Split
/// the parsed filter list into "LZMA2 properties" and "the
/// pre-filter chain (already in encode-order)".
fn split_filter_chain(
  filters: List(#(Int, Int)),
) -> Result(#(Int, List(#(Int, Int))), error.CodecError) {
  case filters {
    [] -> Error(error.CodecInvalidData(message: "xz block has no filters"))
    _ -> {
      // The last filter must be LZMA2.
      let reversed = list.reverse(filters)
      case reversed {
        [] -> Error(error.CodecInvalidData(message: "xz block has no filters"))
        [#(id, _), ..] if id != 0x21 ->
          Error(error.CodecNotImplemented(
            feature: "xz blocks whose final filter is not LZMA2",
          ))
        [#(_, props), ..pre_reversed] -> {
          // Validate every earlier filter is one we can apply.
          let pre_filters = list.reverse(pre_reversed)
          use _ <- result.try(validate_pre_filters(pre_filters))
          Ok(#(props, pre_filters))
        }
      }
    }
  }
}

fn validate_pre_filters(
  filters: List(#(Int, Int)),
) -> Result(Nil, error.CodecError) {
  case filters {
    [] -> Ok(Nil)
    [#(0x03, _), ..rest] -> validate_pre_filters(rest)
    [#(0x04, _), ..rest] -> validate_pre_filters(rest)
    [#(0x05, _), ..rest] -> validate_pre_filters(rest)
    [#(0x07, _), ..rest] -> validate_pre_filters(rest)
    [#(0x08, _), ..rest] -> validate_pre_filters(rest)
    [#(0x09, _), ..rest] -> validate_pre_filters(rest)
    [#(0x0A, _), ..rest] -> validate_pre_filters(rest)
    [#(id, _), ..] ->
      Error(error.CodecNotImplemented(
        feature: "xz pre-processor filter id " <> int.to_string(id),
      ))
  }
}

/// Apply every pre-filter in REVERSE order so the bytes seen by
/// the user match the encoder's input.  Delta is the only
/// pre-processor we currently invert.
fn apply_pre_filters_reverse(
  bytes: BitArray,
  filters: List(#(Int, Int)),
) -> Result(BitArray, error.CodecError) {
  apply_pre_filters_loop(bytes, list.reverse(filters))
}

fn apply_pre_filters_loop(
  bytes: BitArray,
  reversed_filters: List(#(Int, Int)),
) -> Result(BitArray, error.CodecError) {
  case reversed_filters {
    [] -> Ok(bytes)
    [#(0x03, props), ..rest] -> {
      // Delta filter property byte stores `distance - 1` so
      // distances 1..256 fit in one byte.
      let distance = props + 1
      apply_pre_filters_loop(delta_decode(bytes, distance), rest)
    }
    [#(0x04, _), ..rest] -> {
      // x86 BCJ filter — xz resets the encoder's `now_pos` to 0 at
      // every block boundary so the decoder does the same.
      apply_pre_filters_loop(bcj.x86_decode(bytes, 0), rest)
    }
    [#(0x05, _), ..rest] -> {
      // PowerPC (big-endian) BCJ filter.
      apply_pre_filters_loop(bcj.powerpc_decode(bytes, 0), rest)
    }
    [#(0x07, _), ..rest] -> {
      // ARM A32 BCJ filter — same `now_pos = 0` block-reset
      // convention as the x86 filter.
      apply_pre_filters_loop(bcj.arm_decode(bytes, 0), rest)
    }
    [#(0x08, _), ..rest] -> {
      // ARM-Thumb (T32) BCJ filter.
      apply_pre_filters_loop(bcj.armthumb_decode(bytes, 0), rest)
    }
    [#(0x09, _), ..rest] -> {
      // SPARC BCJ filter.
      apply_pre_filters_loop(bcj.sparc_decode(bytes, 0), rest)
    }
    [#(0x0A, _), ..rest] -> {
      // ARM64 (AArch64) BCJ filter — handles BL + ADRP rewrites.
      apply_pre_filters_loop(bcj.arm64_decode(bytes, 0), rest)
    }
    [#(id, _), ..] ->
      Error(error.CodecNotImplemented(
        feature: "xz pre-processor filter id " <> int.to_string(id),
      ))
  }
}

/// Delta decode: output[i] = input[i] + output[i - distance] mod 256.
/// For the first `distance` bytes there's no predecessor so they
/// pass through unchanged.
fn delta_decode(bytes: BitArray, distance: Int) -> BitArray {
  let bytes_list = bit_array_to_byte_list(bytes, [])
  let decoded = delta_decode_loop(bytes_list, distance, [], 0)
  byte_list_to_bit_array(decoded, <<>>)
}

fn delta_decode_loop(
  remaining: List(Int),
  distance: Int,
  acc_reversed: List(Int),
  count: Int,
) -> List(Int) {
  case remaining {
    [] -> list.reverse(acc_reversed)
    [b, ..rest] -> {
      let prev = case count >= distance {
        True -> nth_from_end(acc_reversed, distance - 1)
        False -> 0
      }
      let decoded_byte = int.bitwise_and(b + prev, 0xFF)
      delta_decode_loop(
        rest,
        distance,
        [decoded_byte, ..acc_reversed],
        count + 1,
      )
    }
  }
}

fn nth_from_end(reversed_list: List(Int), index: Int) -> Int {
  // `reversed_list` is the output so far in newest-first order;
  // index 0 is the latest decoded byte, index `distance-1` is the
  // byte at offset `distance` behind the cursor.
  case reversed_list, index {
    [], _ -> 0
    [head, ..], 0 -> head
    [_, ..rest], _ -> nth_from_end(rest, index - 1)
  }
}

fn bit_array_to_byte_list(bytes: BitArray, acc: List(Int)) -> List(Int) {
  case bytes {
    <<b, rest:bytes>> -> bit_array_to_byte_list(rest, [b, ..acc])
    _ -> list.reverse(acc)
  }
}

fn byte_list_to_bit_array(bytes: List(Int), acc: BitArray) -> BitArray {
  case bytes {
    [] -> acc
    [b, ..rest] -> byte_list_to_bit_array(rest, <<acc:bits, b>>)
  }
}

// -- LZMA2 stream -------------------------------------------------------

fn decode_lzma2(
  payload: BitArray,
  default_props: Int,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  let initial = case lzma.properties_of_byte(default_props) {
    Ok(p) -> p
    Error(_) -> lzma.Properties(lc: 3, lp: 0, pb: 2)
  }
  decode_lzma2_loop(payload, <<>>, initial, limits)
}

fn decode_lzma2_loop(
  payload: BitArray,
  output: BitArray,
  props: lzma.Properties,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  case payload {
    <<0x00, _:bytes>> -> Ok(output)
    <<control, _:bytes>> if control == 0x01 || control == 0x02 -> {
      case payload {
        <<_control, size_high, size_low, rest:bytes>> -> {
          let size =
            int.bitwise_or(int.bitwise_shift_left(size_high, 8), size_low) + 1
          use data <- result.try(slice_required(
            rest,
            0,
            size,
            "lzma2 uncompressed chunk",
          ))
          use new_output <- result.try(append_with_limit(output, data, limits))
          let assert Ok(next) =
            bit_array.slice(rest, size, bit_array.byte_size(rest) - size)
          decode_lzma2_loop(next, new_output, props, limits)
        }
        _ ->
          Error(error.CodecInvalidData(
            message: "truncated lzma2 uncompressed chunk",
          ))
      }
    }
    <<control, _:bytes>> if control >= 0x80 ->
      decode_lzma2_lzma_chunk(payload, control, output, props, limits)
    <<other, _:bytes>> ->
      Error(error.CodecInvalidData(
        message: "invalid lzma2 control byte " <> int.to_string(other),
      ))
    _ -> Error(error.CodecInvalidData(message: "truncated lzma2 stream"))
  }
}

fn decode_lzma2_lzma_chunk(
  payload: BitArray,
  control: Int,
  output: BitArray,
  props: lzma.Properties,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  let has_new_props = control >= 0xC0
  case payload {
    <<_control, usize_high, usize_low, csize_high, csize_low, rest:bytes>> -> {
      let usize =
        int.bitwise_or(
          int.bitwise_shift_left(int.bitwise_and(control, 0x1F), 16),
          int.bitwise_or(int.bitwise_shift_left(usize_high, 8), usize_low),
        )
        + 1
      let csize =
        int.bitwise_or(int.bitwise_shift_left(csize_high, 8), csize_low) + 1
      use #(new_props, lzma_input, after_chunk) <- result.try(
        case has_new_props {
          True ->
            case rest {
              <<props_byte, rest_after_props:bytes>> -> {
                use parsed_props <- result.try(lzma.properties_of_byte(
                  props_byte,
                ))
                use lzma_data <- result.try(slice_required(
                  rest_after_props,
                  0,
                  csize,
                  "lzma2 LZMA data",
                ))
                let assert Ok(after) =
                  bit_array.slice(
                    rest_after_props,
                    csize,
                    bit_array.byte_size(rest_after_props) - csize,
                  )
                Ok(#(parsed_props, lzma_data, after))
              }
              _ ->
                Error(error.CodecInvalidData(
                  message: "truncated lzma2 properties byte",
                ))
            }
          False -> {
            use lzma_data <- result.try(slice_required(
              rest,
              0,
              csize,
              "lzma2 LZMA data",
            ))
            let assert Ok(after) =
              bit_array.slice(rest, csize, bit_array.byte_size(rest) - csize)
            Ok(#(props, lzma_data, after))
          }
        },
      )
      use decoder <- result.try(lzma.new(
        lzma_input,
        new_props,
        limit.max_output_bytes(limits),
      ))
      use #(decoded, _state) <- result.try(lzma.decode_into(decoder, usize))
      use new_output <- result.try(append_with_limit(output, decoded, limits))
      decode_lzma2_loop(after_chunk, new_output, new_props, limits)
    }
    _ ->
      Error(error.CodecInvalidData(message: "truncated lzma2 LZMA chunk header"))
  }
}

// -- block check --------------------------------------------------------

fn check_size_for(check_type: Int) -> Int {
  case check_type {
    0 -> 0
    1 -> 4
    4 -> 8
    10 -> 32
    _ -> 0
  }
}

fn verify_block_check(
  plain: BitArray,
  check_type: Int,
  check_bytes: BitArray,
) -> Result(Nil, error.CodecError) {
  case check_type {
    0 -> Ok(Nil)
    1 -> {
      let expected = checksum.crc32(plain)
      case expected == bit_array_to_u32_le(check_bytes) {
        True -> Ok(Nil)
        False ->
          Error(error.CodecInvalidData(message: "xz block CRC32 mismatch"))
      }
    }
    4 ->
      // CRC64 verification not implemented; trust the check.  We still
      // confirm the field exists with the expected length.
      case bit_array.byte_size(check_bytes) {
        8 -> Ok(Nil)
        _ -> Error(error.CodecInvalidData(message: "xz block CRC64 length"))
      }
    10 ->
      case bit_array.byte_size(check_bytes) {
        32 -> Ok(Nil)
        _ -> Error(error.CodecInvalidData(message: "xz block SHA-256 length"))
      }
    _ ->
      Error(error.CodecNotImplemented(
        feature: "xz check type " <> int.to_string(check_type),
      ))
  }
}

// -- index + footer ------------------------------------------------------

fn finalize_stream(
  bytes: BitArray,
  check_type: Int,
  output: BitArray,
  records: List(#(Int, Int)),
) -> Result(#(BitArray, BitArray), error.CodecError) {
  use #(num_records, rest) <- result.try(read_varint(bytes))
  use <- bool.guard(
    when: num_records != list.length(records),
    return: Error(error.CodecInvalidData(
      message: "xz index record count does not match blocks",
    )),
  )
  use #(parsed_records, rest) <- result.try(
    read_index_records(rest, num_records, []),
  )
  use <- bool.guard(
    when: parsed_records != records,
    return: Error(error.CodecInvalidData(
      message: "xz index records do not match block sizes",
    )),
  )
  let bytes_after_indicator = varint_size(num_records) + records_size(records)
  let pad = padding_to_align(1 + bytes_after_indicator, 4)
  use <- bool.guard(
    when: pad > 0 && !slice_is_zero(rest, 0, pad),
    return: Error(error.CodecInvalidData(
      message: "xz index padding has non-zero bytes",
    )),
  )
  use crc_bytes <- result.try(slice_required(rest, pad, 4, "xz index CRC32"))
  let crc_input = prepend_indicator_for_crc(bytes, bytes_after_indicator + pad)
  let expected_crc = checksum.crc32(crc_input)
  use <- bool.guard(
    when: expected_crc != bit_array_to_u32_le(crc_bytes),
    return: Error(error.CodecInvalidData(message: "xz index CRC mismatch")),
  )
  let assert Ok(after_index) =
    bit_array.slice(rest, pad + 4, bit_array.byte_size(rest) - pad - 4)
  // The stream footer is always exactly 12 bytes, so the first 12
  // bytes of `after_index` are the footer and everything after that
  // is either inter-stream padding or the next stream.
  case bit_array.slice(after_index, 0, stream_footer_size) {
    Ok(footer) -> {
      use _ <- result.try(verify_stream_footer(footer, check_type))
      let assert Ok(after_footer) =
        bit_array.slice(
          after_index,
          stream_footer_size,
          bit_array.byte_size(after_index) - stream_footer_size,
        )
      Ok(#(output, after_footer))
    }
    _ ->
      Error(error.CodecInvalidData(
        message: "xz stream footer truncated (need 12 bytes)",
      ))
  }
}

fn prepend_indicator_for_crc(
  index_after_indicator: BitArray,
  size_without_indicator: Int,
) -> BitArray {
  // The CRC32 in the xz index covers the indicator (0x00) plus the
  // num_records, records, and padding bytes that precede the CRC.
  case bit_array.slice(index_after_indicator, 0, size_without_indicator) {
    Ok(slice) -> bit_array.concat([<<0x00>>, slice])
    Error(_) -> <<>>
  }
}

fn read_index_records(
  bytes: BitArray,
  remaining: Int,
  acc: List(#(Int, Int)),
) -> Result(#(List(#(Int, Int)), BitArray), error.CodecError) {
  case remaining {
    0 -> Ok(#(list.reverse(acc), bytes))
    _ -> {
      use #(unpadded, bytes) <- result.try(read_varint(bytes))
      use #(uncomp, bytes) <- result.try(read_varint(bytes))
      read_index_records(bytes, remaining - 1, [#(unpadded, uncomp), ..acc])
    }
  }
}

fn verify_stream_footer(
  footer: BitArray,
  check_type: Int,
) -> Result(Nil, error.CodecError) {
  case footer {
    <<
      crc:bytes-size(4),
      backward_size:little-unsigned-size(32),
      flag_zero,
      footer_check,
      0x59,
      0x5A,
    >> -> {
      let _ = backward_size
      use <- bool.guard(
        when: flag_zero != 0,
        return: Error(error.CodecInvalidData(
          message: "xz stream footer reserved byte non-zero",
        )),
      )
      use <- bool.guard(
        when: footer_check != check_type,
        return: Error(error.CodecInvalidData(
          message: "xz stream footer check type does not match header",
        )),
      )
      let expected =
        checksum.crc32(<<
          backward_size:size(32)-little,
          flag_zero,
          footer_check,
        >>)
      use <- bool.guard(
        when: expected != bit_array_to_u32_le(crc),
        return: Error(error.CodecInvalidData(
          message: "xz stream footer CRC mismatch",
        )),
      )
      Ok(Nil)
    }
    _ -> Error(error.CodecInvalidData(message: "invalid xz stream footer"))
  }
}

fn records_size(records: List(#(Int, Int))) -> Int {
  case records {
    [] -> 0
    [#(unp, unc), ..rest] ->
      varint_size(unp) + varint_size(unc) + records_size(rest)
  }
}

// -- varint helpers ------------------------------------------------------

fn read_varint(bytes: BitArray) -> Result(#(Int, BitArray), error.CodecError) {
  read_varint_loop(bytes, 0, 0)
}

fn read_varint_loop(
  bytes: BitArray,
  value: Int,
  shift: Int,
) -> Result(#(Int, BitArray), error.CodecError) {
  case bytes {
    <<b, rest:bytes>> -> {
      let chunk = int.bitwise_and(b, 0x7F)
      let value = int.bitwise_or(value, int.bitwise_shift_left(chunk, shift))
      case int.bitwise_and(b, 0x80) {
        0 -> Ok(#(value, rest))
        _ -> {
          case shift >= 56 {
            True -> Error(error.CodecInvalidData(message: "xz varint overflow"))
            False -> read_varint_loop(rest, value, shift + 7)
          }
        }
      }
    }
    _ -> Error(error.CodecInvalidData(message: "truncated xz varint"))
  }
}

fn varint_size(value: Int) -> Int {
  // The xz spec allows up to 9 bytes (63 bits), but values above
  // 2^49 cannot round-trip exactly on JavaScript's number type, so
  // the table is capped at 8 bytes — every realistic .xz block fits.
  case value {
    n if n < 0x80 -> 1
    n if n < 0x4000 -> 2
    n if n < 0x20_0000 -> 3
    n if n < 0x1000_0000 -> 4
    n if n < 0x8_0000_0000 -> 5
    n if n < 0x400_0000_0000 -> 6
    n if n < 0x2_0000_0000_0000 -> 7
    _ -> 8
  }
}

// -- BitArray helpers ---------------------------------------------------

fn slice_required(
  bytes: BitArray,
  offset: Int,
  length: Int,
  label: String,
) -> Result(BitArray, error.CodecError) {
  case offset, length {
    -1, _ -> Ok(bytes)
    _, -1 -> Ok(bytes)
    _, _ ->
      case bit_array.slice(bytes, offset, length) {
        Ok(value) -> Ok(value)
        Error(_) ->
          Error(error.CodecInvalidData(message: "truncated " <> label))
      }
  }
}

fn slice_is_zero(bytes: BitArray, offset: Int, length: Int) -> Bool {
  case bit_array.slice(bytes, offset, length) {
    Ok(chunk) -> all_zero(chunk)
    Error(_) -> True
  }
}

fn all_zero(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<0, rest:bytes>> -> all_zero(rest)
    _ -> False
  }
}

fn padding_to_align(used: Int, alignment: Int) -> Int {
  let leftover = used % alignment
  case leftover {
    0 -> 0
    _ -> alignment - leftover
  }
}
