import gleam/bit_array
import gleeunit/should
import packkit/snappy

pub fn raw_decode_hello_test() -> Nil {
  // `snappyjs.compress(Buffer.from("hello"))` from npm.
  let compressed = <<0x05, 0x10, 0x68, 0x65, 0x6c, 0x6c, 0x6f>>
  let assert Ok(plain) = snappy.raw_decode(bytes: compressed)
  plain
  |> should.equal(<<"hello":utf8>>)
}

pub fn raw_decode_hello_world_test() -> Nil {
  // `snappyjs.compress(Buffer.from("hello world"))` from npm.
  let compressed = <<
    0x0b, 0x28, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x20, 0x77, 0x6f, 0x72, 0x6c, 0x64,
  >>
  let assert Ok(plain) = snappy.raw_decode(bytes: compressed)
  plain
  |> should.equal(<<"hello world":utf8>>)
}

pub fn raw_decode_repeated_abc_test() -> Nil {
  // 180-byte "abc"*60 via npm snappyjs.  Exercises the 2-byte copy
  // tag path: literal "abc" then back-references of length 64, 64,
  // and 49 from offset 3.
  let compressed = <<
    0xb4, 0x01, 0x08, 0x61, 0x62, 0x63, 0xfe, 0x03, 0x00, 0xfe, 0x03, 0x00, 0xc2,
    0x03, 0x00,
  >>
  let assert Ok(plain) = snappy.raw_decode(bytes: compressed)
  bit_array.byte_size(plain)
  |> should.equal(180)
  let expected =
    bit_array.from_string(
      "abcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabc",
    )
  plain |> should.equal(expected)
}

pub fn framed_roundtrip_short_test() -> Nil {
  let payload = <<"packkit snappy framing":utf8>>
  let assert Ok(framed) = snappy.encode(bytes: payload)
  let assert Ok(restored) = snappy.decode(bytes: framed)
  restored
  |> should.equal(payload)
}

pub fn framed_roundtrip_empty_test() -> Nil {
  let assert Ok(framed) = snappy.encode(bytes: <<>>)
  let assert Ok(restored) = snappy.decode(bytes: framed)
  restored
  |> should.equal(<<>>)
}

pub fn raw_encode_decode_roundtrip_test() -> Nil {
  let payload = <<"raw snappy literal-only round-trip":utf8>>
  let assert Ok(encoded) = snappy.raw_encode(bytes: payload)
  let assert Ok(restored) = snappy.raw_decode(bytes: encoded)
  restored
  |> should.equal(payload)
}

pub fn raw_encode_compresses_run_test() -> Nil {
  // 1 KiB of 'a' — extremely compressible.  The new LZ77 raw
  // encoder must shrink it well below the input size; the previous
  // literal-only encoder produced ~1 KiB + 3 bytes of varint
  // overhead.
  let payload = repeat_byte(0x61, 1024, <<>>)
  let assert Ok(encoded) = snappy.raw_encode(bytes: payload)
  let assert Ok(restored) = snappy.raw_decode(bytes: encoded)
  restored
  |> should.equal(payload)
  // The encoder must shrink the input significantly — the precise
  // output size depends on copy-tag fragmentation, but a 16-fold
  // (or better) reduction is the floor.
  { bit_array.byte_size(encoded) < 64 }
  |> should.be_true
}

pub fn raw_encode_compresses_repeated_pattern_test() -> Nil {
  let payload = bit_array.concat(list_repeat(<<"abcabcabc":utf8>>, 50))
  let assert Ok(encoded) = snappy.raw_encode(bytes: payload)
  let assert Ok(restored) = snappy.raw_decode(bytes: encoded)
  restored
  |> should.equal(payload)
  { bit_array.byte_size(encoded) < bit_array.byte_size(payload) }
  |> should.be_true
}

pub fn framed_encode_compresses_run_test() -> Nil {
  // The framed encoder used to always emit chunk_uncompressed.  After
  // wiring it through `compress_raw_body` it should emit a
  // chunk_compressed chunk whenever the compressed body is shorter
  // than the raw chunk.
  let payload = repeat_byte(0x61, 1024, <<>>)
  let assert Ok(framed) = snappy.encode(bytes: payload)
  let assert Ok(restored) = snappy.decode(bytes: framed)
  restored
  |> should.equal(payload)
  // Framed overhead is the 10-byte stream identifier + 8-byte chunk
  // header (1 + 3 + 4 for type/size/crc) — so a compressed chunk
  // should still fit in well under 100 bytes.
  { bit_array.byte_size(framed) < 100 }
  |> should.be_true
}

pub fn raw_encode_random_short_roundtrip_test() -> Nil {
  let assert Ok(payload) =
    bit_array.base16_decode(
      "DE7374EF0634215A02948D5CBADC072B286F8175B5FE2FA00B1FCCB187702CF8",
    )
  let assert Ok(encoded) = snappy.raw_encode(bytes: payload)
  let assert Ok(restored) = snappy.raw_decode(bytes: encoded)
  restored
  |> should.equal(payload)
}

fn repeat_byte(byte: Int, count: Int, acc: BitArray) -> BitArray {
  case count {
    0 -> acc
    _ -> repeat_byte(byte, count - 1, <<acc:bits, byte>>)
  }
}

fn list_repeat(value: a, n: Int) -> List(a) {
  case n {
    0 -> []
    _ -> [value, ..list_repeat(value, n - 1)]
  }
}
