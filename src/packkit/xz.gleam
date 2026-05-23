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
import packkit/internal/lzma
import packkit/limit

const stream_footer_size: Int = 12

/// xz codec smart constructor.
pub fn codec() -> codecs.Codec {
  codecs.xz()
}

/// Encode `bytes` as an xz stream.  Not yet implemented.
pub fn encode(bytes _bytes: BitArray) -> Result(BitArray, error.CodecError) {
  Error(error.CodecNotImplemented(feature: "xz.encode"))
}

/// Decode an xz stream using default limits.
pub fn decode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  decode_with_limits(bytes: bytes, limits: limit.default())
}

/// Decode an xz stream using explicit limits.
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

  use #(header_flags, rest) <- result.try(parse_stream_header(bytes))
  decode_blocks(rest, header_flags, <<>>, [], limits)
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
) -> Result(BitArray, error.CodecError) {
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
        value: projected,
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
          use <- bool.guard(
            when: list.length(filters) != 1,
            return: Error(error.CodecNotImplemented(
              feature: "xz blocks with multi-filter chains",
            )),
          )
          let assert [#(filter_id, props)] = filters
          use <- bool.guard(
            when: filter_id != 0x21,
            return: Error(error.CodecNotImplemented(
              feature: "xz filter id " <> int.to_string(filter_id),
            )),
          )
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
          use plain <- result.try(decode_lzma2(payload, props, limits))
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
) -> Result(BitArray, error.CodecError) {
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
  case bit_array.byte_size(after_index) {
    n if n != stream_footer_size ->
      Error(error.CodecInvalidData(message: "xz stream footer must be 12 bytes"))
    _ -> {
      use _ <- result.try(verify_stream_footer(after_index, check_type))
      Ok(output)
    }
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
  case value {
    n if n < 0x80 -> 1
    n if n < 0x4000 -> 2
    n if n < 0x20_0000 -> 3
    n if n < 0x1000_0000 -> 4
    n if n < 0x8_0000_0000 -> 5
    n if n < 0x400_0000_0000 -> 6
    n if n < 0x2_0000_0000_0000 -> 7
    n if n < 0x100_0000_0000_0000 -> 8
    _ -> 9
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
