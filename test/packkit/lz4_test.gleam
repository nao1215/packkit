import gleam/bit_array
import gleam/int
import gleeunit/should
import packkit
import packkit/codec
import packkit/internal/lz4
import packkit/internal/xxh32

pub fn decode_hello_golden_test() -> Nil {
  // Generated with the `lz4` npm package: lz4.encode(Buffer.from("hello")).
  let compressed = <<
    0x04, 0x22, 0x4d, 0x18, 0x64, 0x70, 0xb9, 0x06, 0x00, 0x00, 0x00, 0x50, 0x68,
    0x65, 0x6c, 0x6c, 0x6f, 0x00, 0x00, 0x00, 0x00, 0xf9, 0x77, 0x00, 0xfb,
  >>
  let assert Ok(plain) = packkit.decompress(compressed, with: codec.Lz4)
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
  let assert Ok(plain) = packkit.decompress(compressed, with: codec.Lz4)
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
  let assert Ok(plain) = packkit.decompress(compressed, with: codec.Lz4)
  bit_array.byte_size(plain)
  |> should.equal(100)
}

pub fn roundtrip_uncompressed_encoder_test() -> Nil {
  let payload = <<"packkit lz4 frame round-trip":utf8>>
  let assert Ok(frame) = lz4.encode(bytes: payload)
  let assert Ok(restored) = packkit.decompress(frame, with: codec.Lz4)
  restored
  |> should.equal(payload)
}

pub fn roundtrip_empty_payload_test() -> Nil {
  let assert Ok(frame) = lz4.encode(bytes: <<>>)
  let assert Ok(restored) = packkit.decompress(frame, with: codec.Lz4)
  restored
  |> should.equal(<<>>)
}

pub fn encoder_compresses_repeating_payload_test() -> Nil {
  // Highly compressible input — 1 KiB of 'a'.  The new LZ77 encoder
  // must shrink it well below the input size (the previous
  // uncompressed-only encoder added ~12 bytes of framing).
  let payload = repeat_byte(0x61, 1024, <<>>)
  let assert Ok(frame) = lz4.encode(bytes: payload)
  let assert Ok(restored) = packkit.decompress(frame, with: codec.Lz4)
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
  let assert Ok(restored) = packkit.decompress(frame, with: codec.Lz4)
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
  let assert Ok(restored) = packkit.decompress(frame, with: codec.Lz4)
  restored
  |> should.equal(payload)
}

pub fn decodes_frame_with_content_size_test() -> Nil {
  // Rewrite the descriptor of an encoded frame so it carries the
  // content-size flag (0x08) and the 8-byte size, as `lz4 --content-size`
  // writes it.  The decoder must skip the field.
  let payload = <<"hello":utf8>>
  let assert Ok(<<magic:bytes-size(4), _flg, _bd, _hc, blocks:bytes>>) =
    lz4.encode(bytes: payload)
  let descriptor = <<0x68, 0x70, 5:size(32)-little, 0:size(32)>>
  let hc =
    int.bitwise_and(
      int.bitwise_shift_right(xxh32.digest(bytes: descriptor, seed: 0), 8),
      0xFF,
    )
  let frame = bit_array.concat([magic, descriptor, <<hc>>, blocks])
  packkit.decompress(frame, with: codec.Lz4)
  |> should.equal(Ok(payload))
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

pub fn legacy_frame_decode_hello_test() -> Nil {
  // Hand-crafted LZ4 legacy frame.  Legacy magic + one block whose
  // payload is a token byte (lit_len=5, match_len ignored) followed
  // by the 5 literal bytes "hello".  The legacy format has no
  // frame descriptor and no end marker — EOF terminates.
  let fixture = <<
    // legacy magic 0x184C2102 (little-endian)
    0x02, 0x21, 0x4C, 0x18,
    // block_size = 6 (LE 32-bit)
    0x06, 0x00, 0x00, 0x00,
    // token: lit_len=5, no match
    0x50,
    // 5 literals "hello"
    0x68, 0x65, 0x6C, 0x6C, 0x6F,
  >>
  let assert Ok(plain) = packkit.decompress(fixture, with: codec.Lz4)
  plain
  |> should.equal(<<"hello":utf8>>)
}

pub fn legacy_frame_decode_two_blocks_test() -> Nil {
  // Two consecutive blocks "abc" + "xyz" — the legacy stream
  // catenates each block's output into the result without any
  // separator.
  let fixture = <<
    // legacy magic
    0x02, 0x21, 0x4C, 0x18,
    // block 1: size=4 (token + 3 literals "abc")
    0x04, 0x00, 0x00, 0x00, 0x30, 0x61, 0x62, 0x63,
    // block 2: size=4 (token + 3 literals "xyz")
    0x04, 0x00, 0x00, 0x00, 0x30, 0x78, 0x79, 0x7A,
  >>
  let assert Ok(plain) = packkit.decompress(fixture, with: codec.Lz4)
  plain
  |> should.equal(<<"abcxyz":utf8>>)
}
