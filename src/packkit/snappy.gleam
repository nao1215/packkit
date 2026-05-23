//// Snappy raw-block and framed codec.
////
//// `snappy.raw_decode` and `snappy.raw_encode` operate on the original
//// Snappy block format documented in `snappy-format-description`.
//// `snappy.decode` and `snappy.encode` operate on the streaming
//// framed form (`sNaPpY` stream identifier and chunked layout).  The
//// raw encoder runs a greedy 4-byte hash-chain match-finder and
//// emits literal + copy-1 / copy-2 / copy-4 sequences in the
//// canonical block layout; the framed encoder dispatches each chunk
//// through the raw encoder and picks the smaller of the compressed
//// (`0x00`) and uncompressed (`0x01`) chunk types.

import gleam/bit_array
import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/result
import packkit/checksum
import packkit/codec as codecs
import packkit/error
import packkit/limit

const stream_identifier: BitArray = <<
  0xFF, 0x06, 0x00, 0x00, 0x73, 0x4E, 0x61, 0x50, 0x70, 0x59,
>>

const chunk_compressed: Int = 0x00

const chunk_uncompressed: Int = 0x01

const chunk_padding: Int = 0xFE

const chunk_stream_identifier: Int = 0xFF

const max_uncompressed_chunk: Int = 65_536

/// Snappy framed codec smart constructor.
pub fn codec() -> codecs.Codec {
  codecs.snappy()
}

/// Encode `bytes` as a framed Snappy stream that stores every chunk
/// in the uncompressed form.
pub fn encode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  let chunks = encode_uncompressed_chunks(bytes, [])
  Ok(bit_array.concat([stream_identifier, chunks]))
}

/// Decode a framed Snappy stream using the default resource limits.
pub fn decode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  decode_with_limits(bytes: bytes, limits: limit.default())
}

/// Decode a framed Snappy stream using explicit resource limits.
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

  case bytes {
    <<0xFF, 0x06, 0x00, 0x00, 0x73, 0x4E, 0x61, 0x50, 0x70, 0x59, rest:bytes>> ->
      decode_chunks(rest, <<>>, limits)
    _ ->
      Error(error.CodecInvalidData(message: "snappy: missing stream identifier"))
  }
}

/// Decode a single Snappy raw block.
pub fn raw_decode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  raw_decode_with_limits(bytes: bytes, limits: limit.default())
}

/// Decode a Snappy raw block using explicit resource limits.
pub fn raw_decode_with_limits(
  bytes bytes: BitArray,
  limits limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  use #(uncompressed_length, after_varint) <- result.try(read_varint(
    bytes,
    0,
    0,
  ))
  use <- bool.guard(
    when: uncompressed_length > limit.max_output_bytes(limits),
    return: Error(error.CodecLimitExceeded(
      limit: "max_output_bytes",
      actual: uncompressed_length,
    )),
  )

  use output <- result.try(decode_raw_loop(after_varint, <<>>, limits))
  case bit_array.byte_size(output) == uncompressed_length {
    True -> Ok(output)
    False ->
      Error(error.CodecInvalidData(
        message: "snappy: raw output length disagrees with declared length",
      ))
  }
}

/// Encode `bytes` as a Snappy raw block.  Runs a greedy LZ77 match-
/// finder (4-byte hash table, 16-bit hash) and emits literal +
/// copy-1 / copy-2 / copy-4 sequences in the canonical block layout.
/// Inputs of fewer than 4 bytes — where no copy can fit the 4-byte
/// minimum match — degenerate to a single literal run.
pub fn raw_encode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  let length = bit_array.byte_size(bytes)
  let length_varint = write_varint(length)
  let body = compress_raw_body(bytes, length)
  Ok(bit_array.concat([length_varint, body]))
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
      let assert Ok(chunk) = bit_array.slice(remaining, 0, chunk_size)
      let assert Ok(after) =
        bit_array.slice(remaining, chunk_size, total - chunk_size)

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
) -> Result(BitArray, error.CodecError) {
  case bytes {
    <<>> -> Ok(output)
    <<chunk_type, length:size(24)-little, rest:bytes>> -> {
      case bit_array.byte_size(rest) < length {
        True ->
          Error(error.CodecInvalidData(
            message: "snappy: chunk payload truncated",
          ))
        False -> {
          let assert Ok(body) = bit_array.slice(rest, 0, length)
          let assert Ok(after) =
            bit_array.slice(rest, length, bit_array.byte_size(rest) - length)

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
                  Error(error.CodecInvalidData(
                    message: "snappy: repeated stream identifier mismatched",
                  ))
              }
            t if t >= 0x80 -> Ok(output)
            _ ->
              Error(error.CodecInvalidData(
                message: "snappy: unsupported reserved chunk type",
              ))
          })

          decode_chunks(after, new_output, limits)
        }
      }
    }
    _ ->
      Error(error.CodecInvalidData(message: "snappy: chunk header truncated"))
  }
}

fn decode_uncompressed_chunk(
  body: BitArray,
  output: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  case body {
    <<_crc:size(32)-little, data:bytes>> ->
      append_with_limit(output, data, limits)
    _ ->
      Error(error.CodecInvalidData(
        message: "snappy: uncompressed chunk too short",
      ))
  }
}

fn decode_compressed_chunk(
  body: BitArray,
  output: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  case body {
    <<_crc:size(32)-little, payload:bytes>> -> {
      use decoded <- result.try(raw_decode_with_limits(
        bytes: payload,
        limits: limits,
      ))
      append_with_limit(output, decoded, limits)
    }
    _ ->
      Error(error.CodecInvalidData(
        message: "snappy: compressed chunk too short",
      ))
  }
}

fn read_varint(
  bytes: BitArray,
  acc: Int,
  shift: Int,
) -> Result(#(Int, BitArray), error.CodecError) {
  case bytes {
    <<b, rest:bytes>> -> {
      let part = int.bitwise_and(b, 0x7F)
      let acc = int.bitwise_or(acc, int.bitwise_shift_left(part, shift))
      case int.bitwise_and(b, 0x80) {
        0 -> Ok(#(acc, rest))
        _ ->
          case shift > 28 {
            True ->
              Error(error.CodecInvalidData(message: "snappy: oversize varint"))
            False -> read_varint(rest, acc, shift + 7)
          }
      }
    }
    _ ->
      Error(error.CodecInvalidData(message: "snappy: truncated varint length"))
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
) -> Result(BitArray, error.CodecError) {
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
    _ -> Error(error.CodecInvalidData(message: "snappy: malformed raw block"))
  }
}

fn handle_literal(
  tag: Int,
  rest: BitArray,
  output: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  let header = int.bitwise_shift_right(tag, 2)
  use #(length, after_extra) <- result.try(case header {
    h if h < 60 -> Ok(#(h + 1, rest))
    60 -> read_literal_extra(rest, 1)
    61 -> read_literal_extra(rest, 2)
    62 -> read_literal_extra(rest, 3)
    _ -> read_literal_extra(rest, 4)
  })

  case bit_array.byte_size(after_extra) < length {
    True ->
      Error(error.CodecInvalidData(message: "snappy: literal run truncated"))
    False -> {
      let assert Ok(chunk) = bit_array.slice(after_extra, 0, length)
      let assert Ok(after) =
        bit_array.slice(
          after_extra,
          length,
          bit_array.byte_size(after_extra) - length,
        )
      use output <- result.try(append_with_limit(output, chunk, limits))
      decode_raw_loop(after, output, limits)
    }
  }
}

fn read_literal_extra(
  rest: BitArray,
  width: Int,
) -> Result(#(Int, BitArray), error.CodecError) {
  case bit_array.byte_size(rest) < width {
    True ->
      Error(error.CodecInvalidData(
        message: "snappy: literal length extension truncated",
      ))
    False -> {
      let assert Ok(prefix) = bit_array.slice(rest, 0, width)
      let assert Ok(after) =
        bit_array.slice(rest, width, bit_array.byte_size(rest) - width)
      let value = read_le(prefix, width)
      Ok(#(value + 1, after))
    }
  }
}

fn read_le(bytes: BitArray, width: Int) -> Int {
  case width, bytes {
    1, <<b>> -> b
    2, <<b1, b2>> -> b1 + b2 * 256
    3, <<b1, b2, b3>> -> b1 + b2 * 256 + b3 * 65_536
    4, <<b1, b2, b3, b4>> -> b1 + b2 * 256 + b3 * 65_536 + b4 * 16_777_216
    _, _ -> 0
  }
}

fn handle_copy_1(
  tag: Int,
  rest: BitArray,
  output: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  case rest {
    <<offset_low, after_offset:bytes>> -> {
      let length = int.bitwise_and(int.bitwise_shift_right(tag, 2), 0x07) + 4
      let offset_high = int.bitwise_and(int.bitwise_shift_right(tag, 5), 0x07)
      let offset =
        int.bitwise_or(int.bitwise_shift_left(offset_high, 8), offset_low)
      apply_copy(after_offset, output, limits, offset, length)
    }
    _ ->
      Error(error.CodecInvalidData(message: "snappy: copy-1 offset truncated"))
  }
}

fn handle_copy_2(
  tag: Int,
  rest: BitArray,
  output: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  case rest {
    <<offset:size(16)-little, after:bytes>> -> {
      let length = int.bitwise_shift_right(tag, 2) + 1
      apply_copy(after, output, limits, offset, length)
    }
    _ ->
      Error(error.CodecInvalidData(message: "snappy: copy-2 offset truncated"))
  }
}

fn handle_copy_4(
  tag: Int,
  rest: BitArray,
  output: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  case rest {
    <<offset:size(32)-little, after:bytes>> -> {
      let length = int.bitwise_shift_right(tag, 2) + 1
      apply_copy(after, output, limits, offset, length)
    }
    _ ->
      Error(error.CodecInvalidData(message: "snappy: copy-4 offset truncated"))
  }
}

fn apply_copy(
  rest: BitArray,
  output: BitArray,
  limits: limit.Limits,
  offset: Int,
  length: Int,
) -> Result(BitArray, error.CodecError) {
  let size = bit_array.byte_size(output)
  use <- bool.guard(
    when: offset <= 0 || offset > size,
    return: Error(error.CodecInvalidData(
      message: "snappy: copy offset out of bounds",
    )),
  )

  use new_output <- result.try(case offset >= length {
    True -> {
      let assert Ok(chunk) = bit_array.slice(output, size - offset, length)
      append_with_limit(output, chunk, limits)
    }
    False -> copy_byte_by_byte(output, offset, length, limits)
  })
  decode_raw_loop(rest, new_output, limits)
}

fn copy_byte_by_byte(
  output: BitArray,
  offset: Int,
  length: Int,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  case length {
    0 -> Ok(output)
    _ -> {
      let size = bit_array.byte_size(output)
      let assert Ok(byte_slice) = bit_array.slice(output, size - offset, 1)
      use new_output <- result.try(append_with_limit(output, byte_slice, limits))
      copy_byte_by_byte(new_output, offset, length - 1, limits)
    }
  }
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
      let table = build_snappy_byte_table(bytes, 0, dict.new())
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
        _ -> emit_literal(snappy_slice(table, last_lit_start, lit_len, <<>>))
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
    snappy_hash4(
      snappy_byte_at(table, pos),
      snappy_byte_at(table, pos + 1),
      snappy_byte_at(table, pos + 2),
      snappy_byte_at(table, pos + 3),
    )
  case dict.get(hashes, key) {
    Ok(prev) -> {
      let offset = pos - prev
      let valid =
        offset >= 1
        && offset <= snappy_max_distance
        && snappy_bytes4_equal(table, prev, pos)
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
          let match_len = snappy_match_length(table, prev, pos, size, 0)
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
                  emit_literal(
                    snappy_slice(
                      table,
                      last_lit_start,
                      pos - last_lit_start,
                      <<>>,
                    ),
                  )
                False -> <<>>
              }
              let copy = emit_copy_for(offset, match_len, <<>>)
              let next_pos = pos + match_len
              let new_hashes =
                snappy_insert_hashes(
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

fn build_snappy_byte_table(
  bytes: BitArray,
  index: Int,
  acc: dict.Dict(Int, Int),
) -> dict.Dict(Int, Int) {
  case bytes {
    <<b, rest:bytes>> ->
      build_snappy_byte_table(rest, index + 1, dict.insert(acc, index, b))
    _ -> acc
  }
}

fn snappy_byte_at(table: dict.Dict(Int, Int), index: Int) -> Int {
  case dict.get(table, index) {
    Ok(b) -> b
    _ -> 0
  }
}

fn snappy_hash4(b0: Int, b1: Int, b2: Int, b3: Int) -> Int {
  let combined =
    int.bitwise_or(
      b0,
      int.bitwise_or(
        int.bitwise_shift_left(b1, 8),
        int.bitwise_or(
          int.bitwise_shift_left(b2, 16),
          int.bitwise_shift_left(b3, 24),
        ),
      ),
    )
  int.bitwise_and(combined * 2_654_435_761, 0xFFFF)
}

fn snappy_bytes4_equal(table: dict.Dict(Int, Int), p1: Int, p2: Int) -> Bool {
  snappy_byte_at(table, p1) == snappy_byte_at(table, p2)
  && snappy_byte_at(table, p1 + 1) == snappy_byte_at(table, p2 + 1)
  && snappy_byte_at(table, p1 + 2) == snappy_byte_at(table, p2 + 2)
  && snappy_byte_at(table, p1 + 3) == snappy_byte_at(table, p2 + 3)
}

fn snappy_match_length(
  table: dict.Dict(Int, Int),
  base: Int,
  cursor: Int,
  limit_pos: Int,
  acc: Int,
) -> Int {
  case cursor + acc >= limit_pos {
    True -> acc
    False ->
      case
        snappy_byte_at(table, base + acc) == snappy_byte_at(table, cursor + acc)
      {
        True -> snappy_match_length(table, base, cursor, limit_pos, acc + 1)
        False -> acc
      }
  }
}

fn snappy_insert_hashes(
  table: dict.Dict(Int, Int),
  hashes: dict.Dict(Int, Int),
  from: Int,
  to: Int,
  size: Int,
) -> dict.Dict(Int, Int) {
  case from > to || from + snappy_min_match > size {
    True -> hashes
    False -> {
      let key =
        snappy_hash4(
          snappy_byte_at(table, from),
          snappy_byte_at(table, from + 1),
          snappy_byte_at(table, from + 2),
          snappy_byte_at(table, from + 3),
        )
      snappy_insert_hashes(
        table,
        dict.insert(hashes, key, from),
        from + 1,
        to,
        size,
      )
    }
  }
}

fn snappy_slice(
  table: dict.Dict(Int, Int),
  start: Int,
  count: Int,
  acc: BitArray,
) -> BitArray {
  case count {
    0 -> acc
    _ ->
      snappy_slice(table, start + 1, count - 1, <<
        acc:bits,
        snappy_byte_at(table, start),
      >>)
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
