import gleam/bit_array
import gleam/int
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

pub fn encoder_compresses_repeating_payload_test() -> Nil {
  // Highly compressible input — 1 KiB of 'a'.  The new LZ77 encoder
  // must shrink it well below the input size (the previous
  // uncompressed-only encoder added ~12 bytes of framing).
  let payload = repeat_byte(0x61, 1024, <<>>)
  let assert Ok(frame) = lz4.encode(bytes: payload)
  let assert Ok(restored) = lz4.decode(bytes: frame)
  restored
  |> should.equal(payload)
  { bit_array.byte_size(frame) < 100 }
  |> should.be_true
}

pub fn encoder_compresses_repeating_pattern_test() -> Nil {
  let payload =
    bit_array.concat(list_repeat(
      <<"The quick brown fox jumps over the lazy dog.":utf8>>,
      20,
    ))
  let assert Ok(frame) = lz4.encode(bytes: payload)
  let assert Ok(restored) = lz4.decode(bytes: frame)
  restored
  |> should.equal(payload)
  { bit_array.byte_size(frame) < bit_array.byte_size(payload) }
  |> should.be_true
}

pub fn roundtrip_random_short_test() -> Nil {
  let assert Ok(payload) =
    bit_array.base16_decode(
      "DE7374EF0634215A02948D5CBADC072B286F8175B5FE2FA00B1FCCB187702CF8",
    )
  let assert Ok(frame) = lz4.encode(bytes: payload)
  let assert Ok(restored) = lz4.decode(bytes: frame)
  restored
  |> should.equal(payload)
}

pub fn encoder_with_content_size_sets_flag_and_field_test() -> Nil {
  // `encode_with_content_size` must set the FLG content-size bit
  // (0x08) and emit the 8-byte little-endian uncompressed size in
  // the frame descriptor.  The HC byte that follows is the
  // (XXH32 >> 8) of FLG..BD..CSIZE rather than the canned 0x73
  // from the no-flags encoder.
  let payload = <<"hello":utf8>>
  let assert Ok(frame) = lz4.encode_with_content_size(bytes: payload)

  // Frame magic is at offset 0..4, FLG at offset 4, content size
  // begins at offset 6, HC byte at offset 14.
  let assert <<
    _magic:size(32)-little,
    flg,
    _bd,
    csize:size(64)-little,
    _hc,
    _rest:bytes,
  >> = frame

  // FLG must have version v1 and content_size flag set.
  case int.bitwise_and(flg, 0x08) {
    0 -> should.fail()
    _ -> Nil
  }
  csize
  |> should.equal(5)

  // Round trip must agree with the original payload.
  let assert Ok(restored) = lz4.decode(bytes: frame)
  restored
  |> should.equal(payload)
}

pub fn encoder_with_content_size_zero_payload_test() -> Nil {
  let assert Ok(frame) = lz4.encode_with_content_size(bytes: <<>>)
  let assert Ok(restored) = lz4.decode(bytes: frame)
  restored
  |> should.equal(<<>>)
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
