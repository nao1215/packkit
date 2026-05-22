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
