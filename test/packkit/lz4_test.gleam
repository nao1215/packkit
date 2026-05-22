import gleam/bit_array
import gleeunit/should
import packkit/lz4

pub fn decode_hello_golden_test() -> Nil {
  // Generated with the `lz4` npm package: lz4.encode(Buffer.from("hello")).
  let compressed = <<
    0x04, 0x22, 0x4d, 0x18, 0x64, 0x70, 0xb9, 0x06, 0x00, 0x00, 0x00, 0x50, 0x68,
    0x65, 0x6c, 0x6c, 0x6f, 0x00, 0x00, 0x00, 0x00, 0xf9, 0x77, 0x00, 0xfb,
  >>
  let assert Ok(plain) = lz4.decode(bytes: compressed)
  plain
  |> should.equal(<<"hello":utf8>>)
}

pub fn decode_match_run_golden_test() -> Nil {
  // 180-byte "abc"*60 compressed via the `lz4` npm package; exercises
  // the literal-length and match-length 15-extension paths and the
  // overlapping back-reference branch.
  let compressed = <<
    0x04, 0x22, 0x4d, 0x18, 0x64, 0x70, 0xb9, 0x0d, 0x00, 0x00, 0x00, 0x3f, 0x61,
    0x62, 0x63, 0x03, 0x00, 0x99, 0x50, 0x62, 0x63, 0x61, 0x62, 0x63, 0x00, 0x00,
    0x00, 0x00, 0x99, 0x5b, 0x93, 0x15,
  >>
  let assert Ok(plain) = lz4.decode(bytes: compressed)
  bit_array.byte_size(plain)
  |> should.equal(180)
  let expected =
    bit_array.from_string(
      "abcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabc",
    )
  plain |> should.equal(expected)
}

pub fn decode_repeat_offset1_golden_test() -> Nil {
  // 100-byte "x"*100 via npm `lz4`; exercises offset=1 overlapping
  // copies in the back-reference path.
  let compressed = <<
    0x04, 0x22, 0x4d, 0x18, 0x64, 0x70, 0xb9, 0x0b, 0x00, 0x00, 0x00, 0x1f, 0x78,
    0x01, 0x00, 0x4b, 0x50, 0x78, 0x78, 0x78, 0x78, 0x78, 0x00, 0x00, 0x00, 0x00,
    0x3a, 0x0d, 0xd3, 0x4b,
  >>
  let assert Ok(plain) = lz4.decode(bytes: compressed)
  bit_array.byte_size(plain)
  |> should.equal(100)
}

pub fn roundtrip_uncompressed_encoder_test() -> Nil {
  let payload = <<"packkit lz4 frame round-trip":utf8>>
  let assert Ok(frame) = lz4.encode(bytes: payload)
  let assert Ok(restored) = lz4.decode(bytes: frame)
  restored
  |> should.equal(payload)
}

pub fn roundtrip_empty_payload_test() -> Nil {
  let assert Ok(frame) = lz4.encode(bytes: <<>>)
  let assert Ok(restored) = lz4.decode(bytes: frame)
  restored
  |> should.equal(<<>>)
}
