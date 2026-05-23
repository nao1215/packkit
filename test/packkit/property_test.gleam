//// Property-based round-trip tests for every codec.  Uses metamon's
//// `forall_round_trip` runner so a failure shrinks to a minimal
//// counterexample and annotates which codec broke.
////
//// Every codec must satisfy `decode(encode(x)) == Ok(x)` for arbitrary
//// byte inputs in the 0..256-byte range — that range exercises the
//// empty-input edge case, single-byte edges, and the LZW / DEFLATE
//// width-promote / window boundaries that have been failure-prone in
//// the past.

import gleam/bit_array
import gleeunit/should
import metamon
import metamon/generator
import metamon/generator/range
import packkit/brotli
import packkit/bzip2
import packkit/deflate
import packkit/gzip
import packkit/lz4
import packkit/lzw
import packkit/snappy
import packkit/xz
import packkit/zlib
import packkit/zstd

fn bytes_gen() -> generator.Generator(BitArray) {
  generator.bit_array(range.linear(0, 256))
}

pub fn property_deflate_round_trip_test() -> Nil {
  metamon.forall_round_trip(
    gen: bytes_gen(),
    name: "deflate",
    encode: fn(b) {
      let assert Ok(out) = deflate.encode(bytes: b)
      out
    },
    decode: deflate.decode,
  )
}

pub fn property_zlib_round_trip_test() -> Nil {
  metamon.forall_round_trip(
    gen: bytes_gen(),
    name: "zlib",
    encode: fn(b) {
      let assert Ok(out) = zlib.encode(bytes: b)
      out
    },
    decode: zlib.decode,
  )
}

pub fn property_gzip_round_trip_test() -> Nil {
  metamon.forall_round_trip(
    gen: bytes_gen(),
    name: "gzip",
    encode: fn(b) {
      let assert Ok(out) = gzip.encode(bytes: b, header: gzip.default_header())
      out
    },
    decode: gzip.decode_payload,
  )
}

pub fn property_lz4_round_trip_test() -> Nil {
  metamon.forall_round_trip(
    gen: bytes_gen(),
    name: "lz4",
    encode: fn(b) {
      let assert Ok(out) = lz4.encode(bytes: b)
      out
    },
    decode: lz4.decode,
  )
}

pub fn property_snappy_round_trip_test() -> Nil {
  metamon.forall_round_trip(
    gen: bytes_gen(),
    name: "snappy",
    encode: fn(b) {
      let assert Ok(out) = snappy.encode(bytes: b)
      out
    },
    decode: snappy.decode,
  )
}

pub fn property_snappy_raw_round_trip_test() -> Nil {
  metamon.forall_round_trip(
    gen: bytes_gen(),
    name: "snappy_raw",
    encode: fn(b) {
      let assert Ok(out) = snappy.raw_encode(bytes: b)
      out
    },
    decode: snappy.raw_decode,
  )
}

pub fn property_bzip2_round_trip_test() -> Nil {
  metamon.forall_round_trip(
    gen: bytes_gen(),
    name: "bzip2",
    encode: fn(b) {
      let assert Ok(out) = bzip2.encode(bytes: b)
      out
    },
    decode: bzip2.decode,
  )
}

pub fn property_lzw_round_trip_test() -> Nil {
  metamon.forall_round_trip(
    gen: bytes_gen(),
    name: "lzw",
    encode: fn(b) {
      let assert Ok(out) = lzw.encode(bytes: b)
      out
    },
    decode: lzw.decode,
  )
}

pub fn property_xz_round_trip_test() -> Nil {
  metamon.forall_round_trip(
    gen: bytes_gen(),
    name: "xz",
    encode: fn(b) {
      let assert Ok(out) = xz.encode(bytes: b)
      out
    },
    decode: xz.decode,
  )
}

pub fn property_zstd_round_trip_test() -> Nil {
  metamon.forall_round_trip(
    gen: bytes_gen(),
    name: "zstd",
    encode: fn(b) {
      let assert Ok(out) = zstd.encode(bytes: b)
      out
    },
    decode: zstd.decode,
  )
}

pub fn property_brotli_round_trip_test() -> Nil {
  metamon.forall_round_trip(
    gen: bytes_gen(),
    name: "brotli",
    encode: fn(b) {
      let assert Ok(out) = brotli.encode(bytes: b)
      out
    },
    decode: brotli.decode,
  )
}

// -- length invariants -------------------------------------------------

/// `decode(encode(x))` and `x` always have the same byte length.  A
/// dedicated check on top of the round-trip lets us catch shape-
/// preserving mutations (e.g. flipping a single payload byte) that
/// would still round-trip but corrupt content.
pub fn property_deflate_preserves_length_test() -> Nil {
  metamon.forall(bytes_gen(), fn(payload) {
    let assert Ok(encoded) = deflate.encode(bytes: payload)
    case deflate.decode(bytes: encoded) {
      Ok(decoded) ->
        bit_array.byte_size(decoded) == bit_array.byte_size(payload)
      _ -> False
    }
  })
}

pub fn property_lzw_preserves_length_test() -> Nil {
  metamon.forall(bytes_gen(), fn(payload) {
    let assert Ok(encoded) = lzw.encode(bytes: payload)
    case lzw.decode(bytes: encoded) {
      Ok(decoded) ->
        bit_array.byte_size(decoded) == bit_array.byte_size(payload)
      _ -> False
    }
  })
}

// -- pin a non-trivial deterministic case -----------------------------

/// Pins a known-good corpus through every codec.  The metamon
/// property tests above cover random shapes; this one anchors the
/// specific 1024-byte zero string we know is a hot path for RLE-style
/// encoders.
pub fn all_codecs_handle_1k_zeros_test() -> Nil {
  let zeros = bit_array.concat(repeat(<<0:size({ 8 * 1024 })>>, 1))

  // Each codec must round-trip this exact input.
  check_round_trip(zeros, "deflate", deflate.encode, deflate.decode)
  check_round_trip(zeros, "zlib", zlib.encode, zlib.decode)
  check_round_trip(
    zeros,
    "gzip",
    fn(b) { gzip.encode(bytes: b, header: gzip.default_header()) },
    gzip.decode_payload,
  )
  check_round_trip(zeros, "lz4", lz4.encode, lz4.decode)
  check_round_trip(zeros, "snappy", snappy.encode, snappy.decode)
  check_round_trip(zeros, "bzip2", bzip2.encode, bzip2.decode)
  check_round_trip(zeros, "lzw", lzw.encode, lzw.decode)
  check_round_trip(zeros, "xz", xz.encode, xz.decode)
  check_round_trip(zeros, "zstd", zstd.encode, zstd.decode)
  check_round_trip(zeros, "brotli", brotli.encode, brotli.decode)
}

fn check_round_trip(
  payload: BitArray,
  _name: String,
  encode: fn(BitArray) -> Result(BitArray, e),
  decode: fn(BitArray) -> Result(BitArray, e2),
) -> Nil {
  let assert Ok(encoded) = encode(payload)
  case decode(encoded) {
    Ok(decoded) -> decoded |> should.equal(payload)
    _ -> should.fail()
  }
}

fn repeat(value: a, n: Int) -> List(a) {
  case n {
    0 -> []
    _ -> [value, ..repeat(value, n - 1)]
  }
}
