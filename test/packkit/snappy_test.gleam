import gleam/bit_array
import gleeunit/should
import packkit
import packkit/codec
import packkit/internal/checksum
import packkit/internal/snappy

// Wraps a raw block in a framed stream: the stream identifier, then one
// compressed chunk with the masked CRC-32C of `plain`.
fn framed(raw: BitArray, plain: BitArray) -> BitArray {
  let crc = checksum.snappy_mask(crc: checksum.crc32c(data: plain))
  let length = bit_array.byte_size(raw) + 4
  <<
    0xFF, 0x06, 0x00, 0x00, "sNaPpY", 0x00, length:size(24)-little,
    crc:size(32)-little, raw:bits,
  >>
}

fn raw_decode(
  raw: BitArray,
  plain: BitArray,
) -> Result(BitArray, codec.CodecError) {
  packkit.decompress(framed(raw, plain), with: codec.Snappy)
}

fn round_trip(payload: BitArray) -> BitArray {
  let assert Ok(encoded) = packkit.compress(payload, with: codec.Snappy)
  let assert Ok(restored) = packkit.decompress(encoded, with: codec.Snappy)
  assert restored == payload
  encoded
}

pub fn raw_decode_hello_test() -> Nil {
  // `snappyjs.compress(Buffer.from("hello"))` from npm.
  let compressed = <<0x05, 0x10, 0x68, 0x65, 0x6c, 0x6c, 0x6f>>
  let assert Ok(plain) = raw_decode(compressed, <<"hello">>)
  plain
  |> should.equal(<<"hello":utf8>>)
}

pub fn raw_decode_hello_world_test() -> Nil {
  // `snappyjs.compress(Buffer.from("hello world"))` from npm.
  let compressed = <<
    0x0b, 0x28, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x20, 0x77, 0x6f, 0x72, 0x6c, 0x64,
  >>
  let assert Ok(plain) = raw_decode(compressed, <<"hello world">>)
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
  let expected =
    bit_array.from_string(
      "abcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabc",
    )
  let assert Ok(plain) = raw_decode(compressed, expected)
  bit_array.byte_size(plain)
  |> should.equal(180)
  plain |> should.equal(expected)
}

pub fn framed_roundtrip_short_test() -> Nil {
  let payload = <<"packkit snappy framing":utf8>>
  let assert Ok(framed) = snappy.encode(bytes: payload)
  let assert Ok(restored) = packkit.decompress(framed, with: codec.Snappy)
  restored
  |> should.equal(payload)
}

pub fn framed_roundtrip_empty_test() -> Nil {
  let assert Ok(framed) = snappy.encode(bytes: <<>>)
  let assert Ok(restored) = packkit.decompress(framed, with: codec.Snappy)
  restored
  |> should.equal(<<>>)
}

pub fn compresses_repeated_pattern_test() -> Nil {
  let payload = bit_array.concat(list_repeat(<<"abcabcabc":utf8>>, 50))
  let encoded = round_trip(payload)
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
  let assert Ok(restored) = packkit.decompress(framed, with: codec.Snappy)
  restored
  |> should.equal(payload)
  // Framed overhead is the 10-byte stream identifier + 8-byte chunk
  // header (1 + 3 + 4 for type/size/crc) — so a compressed chunk
  // should still fit in well under 100 bytes.
  { bit_array.byte_size(framed) < 100 }
  |> should.be_true
}

pub fn random_short_roundtrip_test() -> Nil {
  let assert Ok(payload) =
    bit_array.base16_decode(
      "DE7374EF0634215A02948D5CBADC072B286F8175B5FE2FA00B1FCCB187702CF8",
    )
  round_trip(payload)
  Nil
}

pub fn literal_only_roundtrip_test() -> Nil {
  round_trip(<<"raw snappy literal-only round-trip":utf8>>)
  Nil
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
