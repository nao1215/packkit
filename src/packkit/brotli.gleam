//// Brotli codec — partial pure-Gleam decoder.
////
//// The decoder currently handles:
////
//// * The canonical empty stream `0x3F`.
//// * Any stream that uses only uncompressed metablocks
////   (`ISUNCOMPRESSED` bit set) — i.e. payloads that brotli chose
////   not to compress.
////
//// For compressed metablocks the decoder reads the metablock header
//// up to and including the per-block-type context modes, but does
//// not yet decode prefix-code descriptors, context maps, or the
//// command loop.  Those return a typed `CodecNotImplemented` error
//// whose `feature` string names the missing stage.  The ~120 KiB
//// RFC 7932 static dictionary is also still pending.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/result
import packkit/codec as codecs
import packkit/error
import packkit/limit

/// Brotli codec smart constructor.
pub fn codec() -> codecs.Codec {
  codecs.brotli()
}

/// Encode `bytes` as a Brotli stream.  Not yet implemented.
pub fn encode(bytes _bytes: BitArray) -> Result(BitArray, error.CodecError) {
  Error(error.CodecNotImplemented(feature: "brotli.encode"))
}

/// Decode a Brotli stream using default limits.
pub fn decode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  decode_with_limits(bytes: bytes, limits: limit.default())
}

/// Decode a Brotli stream using explicit limits.
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

  let reader = new_reader(bytes)
  use #(_wbits, reader) <- result.try(read_wbits(reader))
  decode_metablocks(reader, <<>>, limits)
}

// -- metablock loop -----------------------------------------------------

fn decode_metablocks(
  reader: Reader,
  output: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  use #(is_last, reader) <- result.try(read_bits(reader, 1))
  case is_last {
    1 -> {
      use #(is_last_empty, reader) <- result.try(read_bits(reader, 1))
      case is_last_empty {
        1 -> Ok(output)
        _ -> {
          use #(output, _reader) <- result.try(decode_one_metablock(
            reader,
            output,
            limits,
            True,
          ))
          Ok(output)
        }
      }
    }
    _ -> {
      use #(output, reader) <- result.try(decode_one_metablock(
        reader,
        output,
        limits,
        False,
      ))
      decode_metablocks(reader, output, limits)
    }
  }
}

fn decode_one_metablock(
  reader: Reader,
  output: BitArray,
  limits: limit.Limits,
  is_last: Bool,
) -> Result(#(BitArray, Reader), error.CodecError) {
  use #(mnibbles_raw, reader) <- result.try(read_bits(reader, 2))
  let mnibbles = case mnibbles_raw {
    0 -> 4
    1 -> 5
    2 -> 6
    _ -> 0
  }
  case mnibbles {
    0 -> decode_skip_metablock(reader, output)
    _ -> {
      use #(mlen_minus_1, reader) <- result.try(read_bits(reader, mnibbles * 4))
      let mlen = mlen_minus_1 + 1
      use #(is_uncompressed, reader) <- result.try(case is_last {
        True -> Ok(#(0, reader))
        False -> read_bits(reader, 1)
      })
      case is_uncompressed {
        1 -> decode_uncompressed_metablock(reader, output, mlen, limits)
        _ -> decode_compressed_metablock(reader, output, mlen, limits)
      }
    }
  }
}

// -- Compressed metablock (RFC 7932 §9.2) ------------------------------
//
// Only the prelude is implemented at this stage: NBLTYPES for the three
// block categories (literal, insert-and-copy, distance), NPOSTFIX +
// NDIRECT, and the literal context modes.  Anything further (prefix-code
// descriptors, context maps, command loop, static dictionary) returns
// `CodecNotImplemented` so callers see exactly which stage is missing.

fn decode_compressed_metablock(
  reader: Reader,
  _output: BitArray,
  _mlen: Int,
  _limits: limit.Limits,
) -> Result(#(BitArray, Reader), error.CodecError) {
  use #(nbl_literal, reader) <- result.try(decode_var_len_uint8(reader))
  use #(nbl_command, reader) <- result.try(decode_var_len_uint8(reader))
  use #(nbl_distance, reader) <- result.try(decode_var_len_uint8(reader))

  // Block switching adds a HTREE_BTYPE + HTREE_BLEN + BLEN prelude per
  // category — we don't read those yet.
  use _ <- result.try(reject_block_switching("literal", nbl_literal))
  use _ <- result.try(reject_block_switching("insert-and-copy", nbl_command))
  use _ <- result.try(reject_block_switching("distance", nbl_distance))

  use #(_npostfix, reader) <- result.try(read_bits(reader, 2))
  use #(_ndirect, reader) <- result.try(read_bits(reader, 4))

  // Per RFC 7932 §7.3 the literal context mode is 2 bits per literal
  // block type (1 entry when NBLTYPES_L == 1).
  use #(_context_modes, _reader) <- result.try(
    read_context_modes(reader, nbl_literal, []),
  )

  Error(error.CodecNotImplemented(
    feature: "brotli prefix-code descriptors, context maps, and command loop (RFC 7932 §3.4–§4)",
  ))
}

fn reject_block_switching(
  category: String,
  count: Int,
) -> Result(Nil, error.CodecError) {
  case count > 1 {
    True ->
      Error(error.CodecNotImplemented(
        feature: "brotli " <> category <> " block switching (NBLTYPES > 1)",
      ))
    False -> Ok(Nil)
  }
}

fn read_context_modes(
  reader: Reader,
  remaining: Int,
  acc: List(Int),
) -> Result(#(List(Int), Reader), error.CodecError) {
  case remaining {
    0 -> Ok(#(list.reverse(acc), reader))
    _ -> {
      use #(mode, reader) <- result.try(read_bits(reader, 2))
      read_context_modes(reader, remaining - 1, [mode, ..acc])
    }
  }
}

// -- RFC 7932 §9.2 variable-length 8-bit integer -----------------------
//
// Encodes a number in 0..255 using 1–11 bits.  Used for NBLTYPES,
// NTREES, and other small population counts.
fn decode_var_len_uint8(
  reader: Reader,
) -> Result(#(Int, Reader), error.CodecError) {
  use #(first, reader) <- result.try(read_bits(reader, 1))
  case first {
    0 -> Ok(#(1, reader))
    _ -> {
      use #(triple, reader) <- result.try(read_bits(reader, 3))
      case triple {
        0 -> Ok(#(2, reader))
        n -> {
          use #(extra, reader) <- result.try(read_bits(reader, n))
          let base = int.bitwise_shift_left(1, n)
          Ok(#(base + extra + 1, reader))
        }
      }
    }
  }
}

fn decode_skip_metablock(
  reader: Reader,
  output: BitArray,
) -> Result(#(BitArray, Reader), error.CodecError) {
  use #(reserved, reader) <- result.try(read_bits(reader, 1))
  use <- bool.guard(
    when: reserved != 0,
    return: Error(error.CodecInvalidData(
      message: "brotli skip metablock reserved bit must be zero",
    )),
  )
  use #(mskipbytes, reader) <- result.try(read_bits(reader, 2))
  use #(mskiplen, reader) <- result.try(case mskipbytes {
    0 -> Ok(#(0, reader))
    n -> read_bits(reader, n * 8)
  })
  let skip = mskiplen + 1
  let reader = align_to_byte(reader)
  let reader = consume_bytes(reader, skip)
  Ok(#(output, reader))
}

fn decode_uncompressed_metablock(
  reader: Reader,
  output: BitArray,
  mlen: Int,
  limits: limit.Limits,
) -> Result(#(BitArray, Reader), error.CodecError) {
  let reader = align_to_byte(reader)
  use #(chunk, reader) <- result.try(take_bytes(reader, mlen))
  let projected = bit_array.byte_size(output) + bit_array.byte_size(chunk)
  case projected > limit.max_output_bytes(limits) {
    True ->
      Error(error.CodecLimitExceeded(
        limit: "max_output_bytes",
        value: projected,
      ))
    False -> Ok(#(bit_array.concat([output, chunk]), reader))
  }
}

// -- WBITS prefix ------------------------------------------------------

/// Read the WBITS prefix per RFC 7932 §9.1.  The encoding is:
///
/// * `0` → 16
/// * `1nnn` where `nnn ≠ 000` → 17 + nnn (range 18..24)
/// * `1000 nnn` where `nnn ≠ 000` and `nnn ≠ 001` → 8 + nnn (range 10..15)
/// * `1000 000` → 17
/// * `1000 001` → reserved / large-window indicator (not supported)
fn read_wbits(reader: Reader) -> Result(#(Int, Reader), error.CodecError) {
  use #(first, reader) <- result.try(read_bits(reader, 1))
  case first {
    0 -> Ok(#(16, reader))
    _ -> read_wbits_after_lead(reader)
  }
}

fn read_wbits_after_lead(
  reader: Reader,
) -> Result(#(Int, Reader), error.CodecError) {
  use #(triple, reader) <- result.try(read_bits(reader, 3))
  case triple {
    0 -> read_wbits_short_range(reader)
    n -> Ok(#(17 + n, reader))
  }
}

fn read_wbits_short_range(
  reader: Reader,
) -> Result(#(Int, Reader), error.CodecError) {
  use #(extra, reader) <- result.try(read_bits(reader, 3))
  case extra {
    0 -> Ok(#(17, reader))
    1 ->
      Error(error.CodecInvalidData(
        message: "brotli large-window WBITS prefix is not supported",
      ))
    n -> Ok(#(8 + n, reader))
  }
}

// -- LSB-first bit reader (with byte-aligned tail access) ---------------

type Reader {
  Reader(source: BitArray, buffer: Int, bits: Int, overflow: Bool)
}

fn new_reader(source: BitArray) -> Reader {
  Reader(source: source, buffer: 0, bits: 0, overflow: False)
}

fn refill(reader: Reader, needed: Int) -> Reader {
  case reader.bits >= needed || reader.overflow {
    True -> reader
    False ->
      case reader.source {
        <<b, rest:bytes>> ->
          refill(
            Reader(
              source: rest,
              buffer: int.bitwise_or(
                reader.buffer,
                int.bitwise_shift_left(b, reader.bits),
              ),
              bits: reader.bits + 8,
              overflow: False,
            ),
            needed,
          )
        _ ->
          Reader(
            source: <<>>,
            buffer: reader.buffer,
            bits: reader.bits,
            overflow: True,
          )
      }
  }
}

fn read_bits(
  reader: Reader,
  count: Int,
) -> Result(#(Int, Reader), error.CodecError) {
  case count {
    0 -> Ok(#(0, reader))
    _ -> {
      let reader = refill(reader, count)
      case reader.bits >= count {
        False ->
          Error(error.CodecInvalidData(message: "truncated brotli bit stream"))
        True -> {
          let mask = int.bitwise_shift_left(1, count) - 1
          let value = int.bitwise_and(reader.buffer, mask)
          Ok(#(
            value,
            Reader(
              source: reader.source,
              buffer: int.bitwise_shift_right(reader.buffer, count),
              bits: reader.bits - count,
              overflow: reader.overflow,
            ),
          ))
        }
      }
    }
  }
}

/// Drop the remaining bits in the current byte so the next byte-level
/// operation aligns to a byte boundary.  This matches brotli's
/// `jump_to_byte_boundary` step before an uncompressed-metablock copy
/// or a skip-metablock skip.
fn align_to_byte(reader: Reader) -> Reader {
  let leftover = reader.bits % 8
  case leftover {
    0 -> reader
    _ -> {
      let value = int.bitwise_shift_right(reader.buffer, leftover)
      let bits = reader.bits - leftover
      Reader(
        source: reader.source,
        buffer: value,
        bits: bits,
        overflow: reader.overflow,
      )
    }
  }
}

fn take_bytes(
  reader: Reader,
  count: Int,
) -> Result(#(BitArray, Reader), error.CodecError) {
  // After align_to_byte, reader.bits is a multiple of 8.  Pull entire
  // bytes from the buffer first, then from source.
  let buffered_bytes = reader.bits / 8
  case count <= buffered_bytes {
    True -> {
      let chunk = bits_to_bit_array(reader.buffer, count, <<>>)
      let remaining_bits = reader.bits - count * 8
      let mask = int.bitwise_shift_left(1, remaining_bits) - 1
      let new_buffer =
        int.bitwise_and(int.bitwise_shift_right(reader.buffer, count * 8), mask)
      Ok(#(
        chunk,
        Reader(
          source: reader.source,
          buffer: new_buffer,
          bits: remaining_bits,
          overflow: reader.overflow,
        ),
      ))
    }
    False -> {
      let buffer_chunk = bits_to_bit_array(reader.buffer, buffered_bytes, <<>>)
      let need = count - buffered_bytes
      case bit_array.slice(reader.source, 0, need) {
        Ok(source_chunk) -> {
          let assert Ok(new_source) =
            bit_array.slice(
              reader.source,
              need,
              bit_array.byte_size(reader.source) - need,
            )
          Ok(#(
            bit_array.concat([buffer_chunk, source_chunk]),
            Reader(source: new_source, buffer: 0, bits: 0, overflow: False),
          ))
        }
        Error(_) ->
          Error(error.CodecInvalidData(
            message: "brotli uncompressed metablock body is truncated",
          ))
      }
    }
  }
}

fn consume_bytes(reader: Reader, count: Int) -> Reader {
  case take_bytes(reader, count) {
    Ok(#(_, r)) -> r
    Error(_) -> reader
  }
}

fn bits_to_bit_array(buffer: Int, count: Int, acc: BitArray) -> BitArray {
  case count {
    0 -> acc
    _ ->
      bits_to_bit_array(int.bitwise_shift_right(buffer, 8), count - 1, <<
        acc:bits,
        int.bitwise_and(buffer, 0xFF),
      >>)
  }
}
