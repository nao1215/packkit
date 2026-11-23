//// Differential tests against independent implementations of the same
//// formats: OTP's zlib, `erlang:crc32` / `adler32` and `crypto` on the
//// Erlang target, Node's zlib and crypto on JavaScript. Random inputs mix
//// arbitrary bytes with runs and repeated phrases so the LZ77 match finder
//// and both Huffman modes are exercised.
////
//// - Everything packkit's DEFLATE, zlib and gzip encoders write, the
////   reference inflates to the original bytes.
//// - Everything the reference compresses, packkit decodes to the original.
//// - The checksums and hashes agree byte for byte.

import gleam/bit_array
import gleam/list
import metamon
import metamon/generator.{type Generator}
import metamon/generator/range
import packkit
import packkit/codec
import packkit/gzip
import packkit/internal/checksum
import packkit/internal/deflate
import packkit/internal/zlib

@external(erlang, "packkit_reference_ffi", "zlib_compress")
@external(javascript, "./packkit_reference_ffi.mjs", "zlib_compress")
fn ref_zlib_compress(hex: String) -> String

@external(erlang, "packkit_reference_ffi", "zlib_uncompress")
@external(javascript, "./packkit_reference_ffi.mjs", "zlib_uncompress")
fn ref_zlib_uncompress(hex: String) -> Result(String, Nil)

@external(erlang, "packkit_reference_ffi", "gzip")
@external(javascript, "./packkit_reference_ffi.mjs", "gzip")
fn ref_gzip(hex: String) -> String

@external(erlang, "packkit_reference_ffi", "gunzip")
@external(javascript, "./packkit_reference_ffi.mjs", "gunzip")
fn ref_gunzip(hex: String) -> Result(String, Nil)

@external(erlang, "packkit_reference_ffi", "raw_deflate")
@external(javascript, "./packkit_reference_ffi.mjs", "raw_deflate")
fn ref_raw_deflate(hex: String) -> String

@external(erlang, "packkit_reference_ffi", "raw_inflate")
@external(javascript, "./packkit_reference_ffi.mjs", "raw_inflate")
fn ref_raw_inflate(hex: String) -> Result(String, Nil)

@external(erlang, "packkit_reference_ffi", "crc32")
@external(javascript, "./packkit_reference_ffi.mjs", "crc32")
fn ref_crc32(hex: String) -> Int

@external(erlang, "packkit_reference_ffi", "adler32")
@external(javascript, "./packkit_reference_ffi.mjs", "adler32")
fn ref_adler32(hex: String) -> Int

@external(erlang, "packkit_reference_ffi", "sha256")
@external(javascript, "./packkit_reference_ffi.mjs", "sha256")
fn ref_sha256(hex: String) -> String

@external(erlang, "packkit_reference_ffi", "hmac_sha1")
@external(javascript, "./packkit_reference_ffi.mjs", "hmac_sha1")
fn ref_hmac_sha1(key: String, data: String) -> String

@external(erlang, "packkit_reference_ffi", "pbkdf2_hmac_sha1")
@external(javascript, "./packkit_reference_ffi.mjs", "pbkdf2_hmac_sha1")
fn ref_pbkdf2_hmac_sha1(
  password: String,
  salt: String,
  iterations: Int,
  length: Int,
) -> String

fn hex(bytes: BitArray) -> String {
  bit_array.base16_encode(bytes)
}

fn unhex(text: String) -> Result(BitArray, Nil) {
  bit_array.base16_decode(text)
}

/// Arbitrary bytes, runs of one byte and repeated phrases, concatenated.
fn payload_gen() -> Generator(BitArray) {
  generator.list_of(
    generator.frequency([
      #(3, generator.bit_array(range.constant(0, 40))),
      #(
        2,
        generator.tuple2(
          generator.byte(),
          generator.int(range.constant(1, 300)),
        )
          |> generator.map(fn(t) { repeat(<<t.0>>, t.1) }),
      ),
      #(
        2,
        generator.tuple2(
          generator.element_of([<<"abc":utf8>>, <<"hello, ":utf8>>, <<0, 255>>]),
          generator.int(range.constant(1, 60)),
        )
          |> generator.map(fn(t) { repeat(t.0, t.1) }),
      ),
      // A random phrase repeated: match distances equal its length.
      #(
        2,
        generator.tuple2(
          generator.bit_array(range.constant(1, 40)),
          generator.int(range.constant(2, 8)),
        )
          |> generator.map(fn(t) { repeat(t.0, t.1) }),
      ),
      // A phrase, filler, the phrase again: one match at a distance anywhere
      // up to about 1.5 KiB, which reaches every distance code bucket
      // boundary below it.
      #(
        2,
        generator.tuple2(
          generator.bit_array(range.constant(3, 24)),
          generator.bit_array(range.constant(0, 1500)),
        )
          |> generator.map(fn(t) { bit_array.concat([t.0, t.1, t.0]) }),
      ),
    ]),
    range.constant(0, 6),
  )
  |> generator.map(bit_array.concat)
}

fn repeat(piece: BitArray, times: Int) -> BitArray {
  list.repeat(piece, times) |> bit_array.concat
}

pub fn reference_inflates_packkit_deflate_test() -> Nil {
  metamon.forall(payload_gen(), fn(data) {
    let assert Ok(fixed) = deflate.encode(bytes: data)
    let dynamic = deflate.encode_dynamic(bytes: data)
    list.all([fixed, dynamic], fn(stream) {
      ref_raw_inflate(hex(stream)) == Ok(hex(data))
    })
  })
}

pub fn packkit_inflates_reference_deflate_test() -> Nil {
  metamon.forall(payload_gen(), fn(data) {
    let assert Ok(stream) = unhex(ref_raw_deflate(hex(data)))
    packkit.decompress(stream, with: codec.Deflate) == Ok(data)
  })
}

pub fn zlib_matches_reference_both_ways_test() -> Nil {
  metamon.forall(payload_gen(), fn(data) {
    let assert Ok(ours) = zlib.encode(bytes: data)
    let assert Ok(theirs) = unhex(ref_zlib_compress(hex(data)))
    ref_zlib_uncompress(hex(ours)) == Ok(hex(data))
    && packkit.decompress(theirs, with: codec.Zlib) == Ok(data)
  })
}

pub fn gzip_matches_reference_both_ways_test() -> Nil {
  metamon.forall(payload_gen(), fn(data) {
    let ours = gzip.encode_without_header(data)
    let assert Ok(theirs) = unhex(ref_gzip(hex(data)))
    ref_gunzip(hex(ours)) == Ok(hex(data))
    && packkit.decompress(theirs, with: codec.Gzip) == Ok(data)
  })
}

pub fn checksums_match_reference_test() -> Nil {
  metamon.forall(payload_gen(), fn(data) {
    checksum.crc32(data: data) == ref_crc32(hex(data))
    && checksum.adler32(data: data) == ref_adler32(hex(data))
    && hex(checksum.sha256(data: data)) == ref_sha256(hex(data))
  })
}

pub fn incremental_checksums_match_one_shot_test() -> Nil {
  metamon.forall(generator.tuple2(payload_gen(), payload_gen()), fn(pair) {
    let #(a, b) = pair
    let whole = bit_array.append(a, b)
    checksum.sha256_finalize(
      state: checksum.sha256_init()
      |> checksum.sha256_update(data: a)
      |> checksum.sha256_update(data: b),
    )
    == checksum.sha256(data: whole)
  })
}

pub fn hmac_and_pbkdf2_match_reference_test() -> Nil {
  metamon.forall(
    generator.tuple3(
      generator.bit_array(range.constant(0, 80)),
      generator.bit_array(range.constant(0, 40)),
      generator.tuple2(
        generator.int(range.constant(1, 3)),
        generator.int(range.constant(1, 50)),
      ),
    ),
    fn(input) {
      let #(key, data, #(iterations, length)) = input
      hex(checksum.hmac_sha1(key: key, data: data))
      == ref_hmac_sha1(hex(key), hex(data))
      && hex(checksum.pbkdf2_hmac_sha1(
        password: key,
        salt: data,
        iterations: iterations,
        dk_len: length,
      ))
      == ref_pbkdf2_hmac_sha1(hex(key), hex(data), iterations, length)
    },
  )
}

/// Bytes that never repeat a 3-byte sequence within `n`, so the only match
/// the encoder can take is the one the test plants.
fn filler(n: Int) -> BitArray {
  filler_loop(n, 0, [])
}

fn filler_loop(n: Int, i: Int, acc: List(Int)) -> BitArray {
  case i >= n {
    True -> acc |> list.reverse |> list.map(fn(b) { <<b>> }) |> bit_array.concat
    False -> filler_loop(n, i + 1, [{ i * 7 + i / 251 * 3 } % 251, ..acc])
  }
}

/// Boundary values of RFC 1951's distance and length codes: a phrase is
/// repeated at the first and last distance of every distance bucket, and
/// matches of every length 3-258 are planted, so an off-by-one bucket
/// choice produces a stream the reference cannot inflate to the input.
pub fn deflate_handles_every_distance_and_length_code_boundary_test() -> Nil {
  let phrase = <<0xFB, 0xFC, 0xFD, 0xFE>>
  let distances = [
    1, 2, 3, 4, 5, 6, 7, 8, 9, 16, 17, 32, 33, 64, 65, 128, 129, 256, 257, 512,
    513, 1024, 1025, 2048, 2049, 4096, 4097, 8192, 8193, 16_384, 16_385, 24_576,
    24_577, 32_768,
  ]
  let at_distances =
    list.map(distances, fn(d) {
      case d < 4 {
        True -> repeat(<<0xFB>>, d + 8)
        False -> bit_array.concat([phrase, filler(d - 4), phrase])
      }
    })
  let at_lengths =
    int_range(3, 258)
    |> list.map(fn(len) {
      let piece = filler(len)
      bit_array.concat([piece, <<0xFF>>, piece])
    })
  list.each(list.append(at_distances, at_lengths), fn(data) {
    let assert Ok(fixed) = deflate.encode(bytes: data)
    let dynamic = deflate.encode_dynamic(bytes: data)
    let assert Ok(theirs) = unhex(ref_raw_deflate(hex(data)))
    let assert True = ref_raw_inflate(hex(fixed)) == Ok(hex(data))
    let assert True = ref_raw_inflate(hex(dynamic)) == Ok(hex(data))
    let assert True =
      packkit.decompress(theirs, with: codec.Deflate) == Ok(data)
    Nil
  })
}

fn int_range(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..int_range(from + 1, to)]
  }
}
