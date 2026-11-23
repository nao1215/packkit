//// Snappy framed codec (`sNaPpY` stream identifier and chunked layout).
////
//// Compressed chunks hold a raw block in the format described in
//// `snappy-format-description`. The raw encoder runs a greedy 4-byte
//// hash-chain match-finder and emits literal + copy-1 / copy-2 /
//// copy-4 sequences; the framed encoder picks the smaller of the
//// compressed (`0x00`) and uncompressed (`0x01`) chunk types.

import gleam/bit_array
import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/result
import packkit/codec
import packkit/internal/bytes
import packkit/internal/checksum
import packkit/internal/lz77
import packkit/limit

const stream_identifier: BitArray = <<
  0xFF, 0x06, 0x00, 0x00, 0x73, 0x4E, 0x61, 0x50, 0x70, 0x59,
>>

const chunk_compressed: Int = 0x00

const chunk_uncompressed: Int = 0x01

const chunk_padding: Int = 0xFE

const chunk_stream_identifier: Int = 0xFF

const max_uncompressed_chunk: Int = 65_536

/// Encode `bytes` as a framed Snappy stream.  Each chunk is stored
/// compressed when that is shorter, and uncompressed otherwise.
pub fn encode(bytes bytes: BitArray) -> Result(BitArray, codec.CodecError) {
  let chunks = encode_uncompressed_chunks(bytes, [])
  Ok(bit_array.concat([stream_identifier, chunks]))
}

/// Decode a framed Snappy stream using explicit resource limits.
pub fn decode_with_limits(
  bytes bytes: BitArray,
  limits limits: limit.Limits,
) -> Result(BitArray, codec.CodecError) {
  use _ <- result.try(bytes.check_input(bytes, limits))

  case bytes {
    <<0xFF, 0x06, 0x00, 0x00, 0x73, 0x4E, 0x61, 0x50, 0x70, 0x59, rest:bytes>> ->
      decode_chunks(rest, <<>>, limits)
    _ -> Error(codec.InvalidData(message: "snappy: missing stream identifier"))
  }
}

/// Decode a Snappy raw block using explicit resource limits.
fn raw_decode_with_limits(
  bytes bytes: BitArray,
  limits limits: limit.Limits,
) -> Result(BitArray, codec.CodecError) {
  use #(uncompressed_length, after_varint) <- result.try(read_varint(
    bytes,
    0,
    0,
  ))
  use <- bool.guard(
    when: uncompressed_length > limits.max_output_bytes,
    return: Error(codec.LimitExceeded(
      limit: "max_output_bytes",
      actual: uncompressed_length,
    )),
  )

  use output <- result.try(decode_raw_loop(after_varint, <<>>, limits))
  case bit_array.byte_size(output) == uncompressed_length {
    True -> Ok(output)
    False ->
      Error(codec.InvalidData(
        message: "snappy: raw output length disagrees with declared length",
      ))
  }
}

fn encode_uncompressed_chunks(
  remaining: BitArray,
  acc: List(BitArray),
) -> BitArray {
  let total = bit_array.byte_size(remaining)
  case total {
    0 -> bit_array.concat(list.reverse(acc))
    _ -> {
      let chunk_size = case total > max_uncompressed_chunk {
        True -> max_uncompressed_chunk
        False -> total
      }
      let #(chunk, after) = bytes.split_at(remaining, chunk_size)

      let crc = checksum.snappy_mask(crc: checksum.crc32c(data: chunk))
      // Try Snappy compression and pick the chunk type that produces
      // the shorter on-wire form.  The compressed chunk body is the
      // raw-block stream (varint length + LZ77 sequences); the
      // uncompressed chunk body is the chunk bytes verbatim.
      let raw_body = encode_raw_block(chunk, chunk_size)
      let raw_body_size = bit_array.byte_size(raw_body)
      let framed = case raw_body_size < chunk_size {
        True -> {
          let payload_size = raw_body_size + 4
          let header = <<
            chunk_compressed,
            payload_size:size(24)-little,
            crc:size(32)-little,
          >>
          bit_array.concat([header, raw_body])
        }
        False -> {
          let payload_size = chunk_size + 4
          let header = <<
            chunk_uncompressed,
            payload_size:size(24)-little,
            crc:size(32)-little,
          >>
          bit_array.concat([header, chunk])
        }
      }
      encode_uncompressed_chunks(after, [framed, ..acc])
    }
  }
}

fn encode_raw_block(bytes: BitArray, size: Int) -> BitArray {
  let varint = write_varint(size)
  let body = compress_raw_body(bytes, size)
  bit_array.concat([varint, body])
}

fn decode_chunks(
  bytes: BitArray,
  output: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, codec.CodecError) {
  case bytes {
    <<>> -> Ok(output)
    <<chunk_type, length:size(24)-little, body:bytes-size(length), after:bytes>> -> {
      use new_output <- result.try(case chunk_type {
        t if t == chunk_uncompressed ->
          decode_uncompressed_chunk(body, output, limits)
        t if t == chunk_compressed ->
          decode_compressed_chunk(body, output, limits)
        t if t == chunk_padding -> Ok(output)
        t if t == chunk_stream_identifier ->
          case body == <<0x73, 0x4E, 0x61, 0x50, 0x70, 0x59>> {
            True -> Ok(output)
            False ->
              Error(codec.InvalidData(
                message: "snappy: repeated stream identifier mismatched",
              ))
          }
        t if t >= 0x80 -> Ok(output)
        _ ->
          Error(codec.InvalidData(
            message: "snappy: unsupported reserved chunk type",
          ))
      })

      decode_chunks(after, new_output, limits)
    }
    <<_, _:size(24), _:bytes>> ->
      Error(codec.InvalidData(message: "snappy: chunk payload truncated"))
    _ -> Error(codec.InvalidData(message: "snappy: chunk header truncated"))
  }
}

// Each data chunk starts with the masked CRC-32C of its uncompressed
// bytes.
fn check_crc(stored: Int, data: BitArray) -> Result(Nil, codec.CodecError) {
  case stored == checksum.snappy_mask(crc: checksum.crc32c(data: data)) {
    True -> Ok(Nil)
    False -> Error(codec.InvalidData(message: "snappy: chunk CRC mismatch"))
  }
}

fn decode_uncompressed_chunk(
  body: BitArray,
  output: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, codec.CodecError) {
  case body {
    <<crc:size(32)-little, data:bytes>> -> {
      use _ <- result.try(check_crc(crc, data))
      bytes.append_with_limit(output, data, limits)
    }
    _ ->
      Error(codec.InvalidData(message: "snappy: uncompressed chunk too short"))
  }
}

fn decode_compressed_chunk(
  body: BitArray,
  output: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, codec.CodecError) {
  case body {
    <<crc:size(32)-little, payload:bytes>> -> {
      use decoded <- result.try(raw_decode_with_limits(
        bytes: payload,
        limits: limits,
      ))
      use _ <- result.try(check_crc(crc, decoded))
      bytes.append_with_limit(output, decoded, limits)
    }
    _ -> Error(codec.InvalidData(message: "snappy: compressed chunk too short"))
  }
}

fn read_varint(
  bytes: BitArray,
  acc: Int,
  shift: Int,
) -> Result(#(Int, BitArray), codec.CodecError) {
  case bytes {
    <<b, rest:bytes>> -> {
      let part = int.bitwise_and(b, 0x7F)
      let acc = int.bitwise_or(acc, int.bitwise_shift_left(part, shift))
      case int.bitwise_and(b, 0x80) {
        0 -> Ok(#(acc, rest))
        _ ->
          case shift > 28 {
            True -> Error(codec.InvalidData(message: "snappy: oversize varint"))
            False -> read_varint(rest, acc, shift + 7)
          }
      }
    }
    _ -> Error(codec.InvalidData(message: "snappy: truncated varint length"))
  }
}

fn write_varint(value: Int) -> BitArray {
  write_varint_loop(value, <<>>)
}

fn write_varint_loop(value: Int, acc: BitArray) -> BitArray {
  case value < 0x80 {
    True -> bit_array.concat([acc, <<value>>])
    False -> {
      let low = int.bitwise_and(value, 0x7F)
      let high = int.bitwise_shift_right(value, 7)
      let byte_value = int.bitwise_or(low, 0x80)
      write_varint_loop(high, bit_array.concat([acc, <<byte_value>>]))
    }
  }
}

fn decode_raw_loop(
  bytes: BitArray,
  output: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, codec.CodecError) {
  case bytes {
    <<>> -> Ok(output)
    <<tag, rest:bytes>> -> {
      let kind = int.bitwise_and(tag, 0x03)
      case kind {
        0 -> handle_literal(tag, rest, output, limits)
        1 -> handle_copy_1(tag, rest, output, limits)
        2 -> handle_copy_2(tag, rest, output, limits)
        _ -> handle_copy_4(tag, rest, output, limits)
      }
    }
    _ -> Error(codec.InvalidData(message: "snappy: malformed raw block"))
  }
}

fn handle_literal(
  tag: Int,
  rest: BitArray,
  output: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, codec.CodecError) {
  let header = int.bitwise_shift_right(tag, 2)
  use #(length, after_extra) <- result.try(case header {
    h if h < 60 -> Ok(#(h + 1, rest))
    60 -> read_literal_extra(rest, 1)
    61 -> read_literal_extra(rest, 2)
    62 -> read_literal_extra(rest, 3)
    _ -> read_literal_extra(rest, 4)
  })

  case after_extra {
    <<chunk:bytes-size(length), after:bytes>> -> {
      use output <- result.try(bytes.append_with_limit(output, chunk, limits))
      decode_raw_loop(after, output, limits)
    }
    _ -> Error(codec.InvalidData(message: "snappy: literal run truncated"))
  }
}

fn read_literal_extra(
  rest: BitArray,
  width: Int,
) -> Result(#(Int, BitArray), codec.CodecError) {
  let bits = width * 8
  case rest {
    <<value:size(bits)-little, after:bytes>> -> Ok(#(value + 1, after))
    _ ->
      Error(codec.InvalidData(
        message: "snappy: literal length extension truncated",
      ))
  }
}

fn handle_copy_1(
  tag: Int,
  rest: BitArray,
  output: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, codec.CodecError) {
  case rest {
    <<offset_low, after_offset:bytes>> -> {
      let length = int.bitwise_and(int.bitwise_shift_right(tag, 2), 0x07) + 4
      let offset_high = int.bitwise_and(int.bitwise_shift_right(tag, 5), 0x07)
      let offset =
        int.bitwise_or(int.bitwise_shift_left(offset_high, 8), offset_low)
      apply_copy(after_offset, output, limits, offset, length)
    }
    _ -> Error(codec.InvalidData(message: "snappy: copy-1 offset truncated"))
  }
}

fn handle_copy_2(
  tag: Int,
  rest: BitArray,
  output: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, codec.CodecError) {
  case rest {
    <<offset:size(16)-little, after:bytes>> -> {
      let length = int.bitwise_shift_right(tag, 2) + 1
      apply_copy(after, output, limits, offset, length)
    }
    _ -> Error(codec.InvalidData(message: "snappy: copy-2 offset truncated"))
  }
}

fn handle_copy_4(
  tag: Int,
  rest: BitArray,
  output: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, codec.CodecError) {
  case rest {
    <<offset:size(32)-little, after:bytes>> -> {
      let length = int.bitwise_shift_right(tag, 2) + 1
      apply_copy(after, output, limits, offset, length)
    }
    _ -> Error(codec.InvalidData(message: "snappy: copy-4 offset truncated"))
  }
}

fn apply_copy(
  rest: BitArray,
  output: BitArray,
  limits: limit.Limits,
  offset: Int,
  length: Int,
) -> Result(BitArray, codec.CodecError) {
  let size = bit_array.byte_size(output)
  use <- bool.guard(
    when: offset <= 0 || offset > size,
    return: Error(codec.InvalidData(
      message: "snappy: copy offset out of bounds",
    )),
  )

  use new_output <- result.try(bytes.copy_back(output, offset, length, limits))
  decode_raw_loop(rest, new_output, limits)
}

// -- raw-block LZ77 compressor -----------------------------------------
//
// Snappy's raw block format encodes each sequence as either a literal
// (low 2 bits of the tag = 00) or a copy (low 2 bits = 01 / 10 / 11
// for 1 / 2 / 4-byte offsets).  Minimum match length is 4.  The
// match-finder mirrors the LZ4 encoder: a 4-byte hash with a single-
// position table keyed on a 16-bit hash, max distance 65 535 (so the
// copy-2 form covers the common case and copy-4 only fires for
// inputs > 64 KiB).

const snappy_min_match: Int = 4

const snappy_max_distance: Int = 65_535

fn compress_raw_body(bytes: BitArray, size: Int) -> BitArray {
  case size < snappy_min_match {
    True -> emit_literal(bytes)
    False -> {
      let table = lz77.table(bytes)
      snappy_compress_loop(table, size, 0, 0, dict.new(), [])
    }
  }
}

fn snappy_compress_loop(
  table: dict.Dict(Int, Int),
  size: Int,
  pos: Int,
  last_lit_start: Int,
  hashes: dict.Dict(Int, Int),
  acc: List(BitArray),
) -> BitArray {
  case pos + snappy_min_match > size {
    True -> {
      let lit_len = size - last_lit_start
      let tail = case lit_len {
        0 -> <<>>
        _ -> emit_literal(lz77.table_slice(table, last_lit_start, lit_len))
      }
      bit_array.concat(list.reverse([tail, ..acc]))
    }
    False -> snappy_step(table, size, pos, last_lit_start, hashes, acc)
  }
}

fn snappy_step(
  table: dict.Dict(Int, Int),
  size: Int,
  pos: Int,
  last_lit_start: Int,
  hashes: dict.Dict(Int, Int),
  acc: List(BitArray),
) -> BitArray {
  let key =
    lz77.hash4(
      lz77.table_at(table, pos),
      lz77.table_at(table, pos + 1),
      lz77.table_at(table, pos + 2),
      lz77.table_at(table, pos + 3),
    )
  case dict.get(hashes, key) {
    Ok(prev) -> {
      let offset = pos - prev
      let valid =
        offset >= 1
        && offset <= snappy_max_distance
        && lz77.same4(table, prev, pos)
      case valid {
        False ->
          snappy_compress_loop(
            table,
            size,
            pos + 1,
            last_lit_start,
            dict.insert(hashes, key, pos),
            acc,
          )
        True -> {
          let match_len = lz77.table_match_length(table, prev, pos, size, 0)
          case match_len < snappy_min_match {
            True ->
              snappy_compress_loop(
                table,
                size,
                pos + 1,
                last_lit_start,
                dict.insert(hashes, key, pos),
                acc,
              )
            False -> {
              let literals = case pos > last_lit_start {
                True ->
                  emit_literal(lz77.table_slice(
                    table,
                    last_lit_start,
                    pos - last_lit_start,
                  ))
                False -> <<>>
              }
              let copy = emit_copy_for(offset, match_len, <<>>)
              let next_pos = pos + match_len
              let new_hashes =
                lz77.insert_hashes4(
                  table,
                  dict.insert(hashes, key, pos),
                  pos + 1,
                  next_pos - 1,
                  size,
                )
              snappy_compress_loop(table, size, next_pos, next_pos, new_hashes, [
                copy,
                literals,
                ..acc
              ])
            }
          }
        }
      }
    }
    _ ->
      snappy_compress_loop(
        table,
        size,
        pos + 1,
        last_lit_start,
        dict.insert(hashes, key, pos),
        acc,
      )
  }
}

/// Emit one or more copy records that together cover a single LZ77
/// match.  The Snappy 1-byte offset form caps match length at 11; the
/// 2- and 4-byte forms cap at 64.  Matches longer than 64 are split
/// into multiple back-to-back copies sharing the same offset.
fn emit_copy_for(offset: Int, length: Int, acc: BitArray) -> BitArray {
  case length {
    0 -> acc
    _ ->
      case offset < 2048 && length >= 4 && length <= 11 {
        True -> {
          let tag =
            int.bitwise_or(
              int.bitwise_shift_left(length - 4, 2),
              int.bitwise_or(
                int.bitwise_shift_left(int.bitwise_shift_right(offset, 8), 5),
                1,
              ),
            )
          <<acc:bits, tag, int.bitwise_and(offset, 0xFF)>>
        }
        False -> {
          let chunk = case length > 64 {
            True -> 64
            False -> length
          }
          let piece = case offset < 65_536 {
            True -> {
              let tag = int.bitwise_or(int.bitwise_shift_left(chunk - 1, 2), 2)
              <<tag, offset:size(16)-little>>
            }
            False -> {
              let tag = int.bitwise_or(int.bitwise_shift_left(chunk - 1, 2), 3)
              <<tag, offset:size(32)-little>>
            }
          }
          emit_copy_for(offset, length - chunk, <<acc:bits, piece:bits>>)
        }
      }
  }
}

fn emit_literal(bytes: BitArray) -> BitArray {
  let length = bit_array.byte_size(bytes)
  case length {
    0 -> <<>>
    _ -> {
      let encoded_len = length - 1
      let header = case encoded_len < 60 {
        True -> <<int.bitwise_shift_left(encoded_len, 2)>>
        False -> {
          let #(extra, width) = literal_extension(encoded_len)
          bit_array.concat([
            <<int.bitwise_shift_left(60 + width - 1, 2)>>,
            extra,
          ])
        }
      }
      bit_array.concat([header, bytes])
    }
  }
}

fn literal_extension(encoded_len: Int) -> #(BitArray, Int) {
  case encoded_len < 0x100 {
    True -> #(<<encoded_len>>, 1)
    False ->
      case encoded_len < 0x10000 {
        True -> #(<<encoded_len:size(16)-little>>, 2)
        False ->
          case encoded_len < 0x1000000 {
            True -> #(<<encoded_len:size(24)-little>>, 3)
            False -> #(<<encoded_len:size(32)-little>>, 4)
          }
      }
  }
}
