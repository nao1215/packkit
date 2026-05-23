//// Brotli codec — partial pure-Gleam decoder.
////
//// The decoder currently parses the RFC 7932 stream prefix
//// (variable-length WBITS) plus the first metablock header far
//// enough to recognise the `ISLAST + ISLASTEMPTY` pattern emitted
//// for an empty payload.  Non-empty streams still require the full
//// RFC 7932 machinery — context modelling, two prefix-code
//// alphabets, and the ~120 KiB built-in static dictionary — which
//// is intentionally deferred and returns `CodecNotImplemented`.

import gleam/bit_array
import gleam/bool
import gleam/int
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
  use #(is_last, reader) <- result.try(read_bits(reader, 1))
  case is_last {
    1 -> {
      use #(is_last_empty, _reader) <- result.try(read_bits(reader, 1))
      case is_last_empty {
        1 -> Ok(<<>>)
        _ ->
          Error(error.CodecNotImplemented(
            feature: "brotli non-empty streams (RFC 7932 metablocks + static dictionary)",
          ))
      }
    }
    _ ->
      Error(error.CodecNotImplemented(
        feature: "brotli non-empty streams (RFC 7932 metablocks + static dictionary)",
      ))
  }
}

// -- WBITS prefix ------------------------------------------------------

fn read_wbits(reader: Reader) -> Result(#(Int, Reader), error.CodecError) {
  use #(first, reader) <- result.try(read_bits(reader, 1))
  case first {
    0 -> Ok(#(16, reader))
    _ -> {
      use #(triple, reader) <- result.try(read_bits(reader, 3))
      case triple {
        0 -> {
          use #(extra, reader) <- result.try(read_bits(reader, 3))
          Ok(#(17 + extra, reader))
        }
        n if n < 4 -> Ok(#(10 + n + 1, reader))
        n -> Ok(#(17 + n, reader))
      }
    }
  }
}

// -- LSB-first bit reader ---------------------------------------------

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
  let reader = refill(reader, count)
  case reader.bits >= count {
    False -> Error(error.CodecInvalidData(message: "truncated brotli prefix"))
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
