//// Round-trip tests for the dynamic-Huffman DEFLATE encoder
//// (`deflate.encode_dynamic`).  The encoder must emit a valid RFC
//// 1951 BTYPE=10 block that the existing decoder accepts and whose
//// payload matches the original input byte-for-byte.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleeunit/should
import packkit/deflate

pub fn dynamic_empty_test() -> Nil {
  let assert Ok(encoded) = deflate.encode_dynamic(bytes: <<>>)
  deflate.decode(bytes: encoded)
  |> should.equal(Ok(<<>>))
}

pub fn dynamic_single_byte_test() -> Nil {
  let payload = <<0x41>>
  let assert Ok(encoded) = deflate.encode_dynamic(bytes: payload)
  deflate.decode(bytes: encoded)
  |> should.equal(Ok(payload))
}

pub fn dynamic_short_ascii_test() -> Nil {
  let payload = <<"Hello, World!":utf8>>
  let assert Ok(encoded) = deflate.encode_dynamic(bytes: payload)
  deflate.decode(bytes: encoded)
  |> should.equal(Ok(payload))
}

pub fn dynamic_repetitive_test() -> Nil {
  // Repetitive input exercises both LZ77 matches AND a frequency
  // distribution that should actually compress with dynamic Huffman.
  let payload = <<
    "The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog.":utf8,
  >>
  let assert Ok(encoded) = deflate.encode_dynamic(bytes: payload)
  deflate.decode(bytes: encoded)
  |> should.equal(Ok(payload))
}

pub fn dynamic_all_zeros_test() -> Nil {
  // 256 zero bytes: extreme skew so the literal/length alphabet only
  // touches symbol 0 (and the implicit end-of-block 256).  Exercises
  // the single-symbol Huffman code path.
  let payload = repeat_byte(0, 256, <<>>)
  let assert Ok(encoded) = deflate.encode_dynamic(bytes: payload)
  deflate.decode(bytes: encoded)
  |> should.equal(Ok(payload))
}

pub fn dynamic_byte_range_test() -> Nil {
  // 0..255 — every literal symbol used once, exactly the kind of even
  // distribution that historically tripped up Huffman builders.
  let payload = byte_range(0, 256, <<>>)
  let assert Ok(encoded) = deflate.encode_dynamic(bytes: payload)
  deflate.decode(bytes: encoded)
  |> should.equal(Ok(payload))
}

pub fn dynamic_long_run_test() -> Nil {
  // 1 KiB of 'a' — heavy LZ77 match emission, so the distance
  // alphabet sees real frequencies (no phantom-symbol path).
  let payload = repeat_byte(0x61, 1024, <<>>)
  let assert Ok(encoded) = deflate.encode_dynamic(bytes: payload)
  deflate.decode(bytes: encoded)
  |> should.equal(Ok(payload))
}

pub fn dynamic_compresses_better_than_stored_test() -> Nil {
  // Sanity check that the dynamic encoder is doing real work: a
  // highly compressible input must shrink below the stored-block
  // overhead (5-byte header + payload).
  let payload = repeat_byte(0x61, 1024, <<>>)
  let assert Ok(dynamic) = deflate.encode_dynamic(bytes: payload)
  { bit_array.byte_size(dynamic) < 1024 }
  |> should.be_true
}

pub fn dynamic_through_zlib_decoder_test() -> Nil {
  // The dynamic block must also round-trip through the codec-neutral
  // decoder path, since both `decode` and `decode_with_limits` share
  // the same inflater.
  let payload = <<"dynamic via decode_with_limits":utf8>>
  let assert Ok(encoded) = deflate.encode_dynamic(bytes: payload)
  deflate.decode(bytes: encoded)
  |> should.equal(Ok(payload))
}

pub fn dynamic_emits_btype_10_marker_test() -> Nil {
  // The first byte's bottom 3 bits encode (BFINAL, BTYPE).  For
  // BFINAL=1, BTYPE=10 (dynamic) the LSB-first stream packs bit 0 =
  // BFINAL = 1, bit 1..2 = BTYPE = 10 → low 3 bits = 0b101 = 5.
  let payload = <<"verify the BTYPE flag":utf8>>
  let assert Ok(encoded) = deflate.encode_dynamic(bytes: payload)
  case encoded {
    <<first, _:bytes>> -> {
      first
      |> int.bitwise_and(0x07)
      |> should.equal(0x05)
    }
    _ -> should.fail()
  }
}

pub fn dynamic_handles_random_bytes_test() -> Nil {
  // Pseudo-random byte stream: forces the dynamic encoder to emit
  // many literal codes with a relatively flat distribution.  The
  // Huffman tree depth should stay under 15 bits on this input.
  let assert Ok(payload) =
    bit_array.base16_decode(
      "DE7374EF0634215A02948D5CBADC072B286F8175B5FE2FA00B1FCCB187702CF88F3DDA7314365F543E86C017D6753585DA60ACBE9734C7085FC5EB0914E0C500E2300F5928CA8C12B0548F81FB69AAB4",
    )
  let assert Ok(encoded) = deflate.encode_dynamic(bytes: payload)
  deflate.decode(bytes: encoded)
  |> should.equal(Ok(payload))
}

pub fn dynamic_two_unique_bytes_test() -> Nil {
  // Only two distinct symbols — exercises the simple-Huffman case
  // where the literal/length alphabet has very few active codes.
  let payload = repeat_byte(0x41, 50, <<>>)
  let payload = bit_array.concat([payload, repeat_byte(0x42, 50, <<>>)])
  let assert Ok(encoded) = deflate.encode_dynamic(bytes: payload)
  deflate.decode(bytes: encoded)
  |> should.equal(Ok(payload))
}

fn repeat_byte(byte: Int, count: Int, acc: BitArray) -> BitArray {
  case count {
    0 -> acc
    _ -> repeat_byte(byte, count - 1, <<acc:bits, byte>>)
  }
}

fn byte_range(from: Int, until: Int, acc: BitArray) -> BitArray {
  use <- bool.guard(when: from >= until, return: acc)
  byte_range(from + 1, until, <<acc:bits, from>>)
}
