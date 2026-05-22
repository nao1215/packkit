import gleam/bit_array
import gleeunit/should
import packkit/deflate

pub fn decode_fixed_huffman_hello_test() -> Nil {
  // Raw deflate for the ASCII string "hello" produced by Python's
  // zlib.compressobj(level=6, wbits=-15).  Uses fixed Huffman.
  let compressed = <<0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0x07, 0x00>>
  let assert Ok(plain) = deflate.decode(bytes: compressed)
  plain
  |> should.equal(<<"hello":utf8>>)
}

pub fn decode_fixed_huffman_repeat_test() -> Nil {
  // 51-byte ASCII string of repeated "abc" sequences.
  let compressed = <<0x4B, 0x4C, 0x4A, 0x4E, 0x24, 0x11, 0x01, 0x00>>
  let assert Ok(plain) = deflate.decode(bytes: compressed)
  bit_array.byte_size(plain)
  |> should.equal(51)
}

pub fn decode_dynamic_huffman_lorem_test() -> Nil {
  let compressed = <<
    0x25, 0xCC, 0xD1, 0x09, 0x03, 0x31, 0x0C, 0x04, 0xD1, 0x56, 0xB6, 0x80, 0x23,
    0x95, 0xA4, 0x09, 0xC5, 0x12, 0xC7, 0x82, 0x65, 0xFB, 0x2C, 0xA9, 0xFF, 0x18,
    0xEE, 0x7B, 0x78, 0xF3, 0x9D, 0xDB, 0x1C, 0x5C, 0x51, 0x0E, 0x9D, 0x7D, 0x6E,
    0x04, 0x13, 0xE2, 0x96, 0x17, 0xDA, 0x1C, 0x61, 0x2D, 0x2D, 0x6B, 0x43, 0x94,
    0x8B, 0xD1, 0x38, 0x6E, 0x58, 0xE7, 0x89, 0x61, 0x7A, 0x00, 0x8C, 0x15, 0x3E,
    0x15, 0x69, 0xBE, 0x0E, 0xE6, 0x68, 0x54, 0x6A, 0x8D, 0x44, 0x25, 0xBA, 0xFC,
    0xCE, 0x1E, 0x96, 0xEF, 0xDA, 0xE0, 0x72, 0x0F, 0x81, 0x74, 0x3E, 0x25, 0x9F,
    0x3F,
  >>

  let assert Ok(plain) = deflate.decode(bytes: compressed)
  bit_array.to_string(plain)
  |> should.equal(Ok(
    "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
  ))
}

pub fn roundtrip_huffman_encoder_test() -> Nil {
  let payload = <<"packkit roundtrip via fixed-huffman deflate":utf8>>
  let assert Ok(compressed) = deflate.encode(bytes: payload)
  let assert Ok(restored) = deflate.decode(bytes: compressed)
  restored
  |> should.equal(payload)
}

pub fn roundtrip_empty_encoder_test() -> Nil {
  let assert Ok(compressed) = deflate.encode(bytes: <<>>)
  let assert Ok(restored) = deflate.decode(bytes: compressed)
  restored
  |> should.equal(<<>>)
}

pub fn roundtrip_stored_encoder_test() -> Nil {
  let payload = <<"packkit roundtrip via stored deflate":utf8>>
  let assert Ok(compressed) = deflate.encode_stored_only(bytes: payload)
  let assert Ok(restored) = deflate.decode(bytes: compressed)
  restored
  |> should.equal(payload)
}

pub fn huffman_encoder_compresses_repetition_test() -> Nil {
  // 1 KiB of the same byte should compress significantly via LZ77
  // back-references.
  let payload = repeat_byte(0x41, 1024, <<>>)
  let assert Ok(compressed) = deflate.encode(bytes: payload)
  let assert Ok(restored) = deflate.decode(bytes: compressed)
  restored
  |> should.equal(payload)
  should.be_true(bit_array.byte_size(compressed) < 64)
}

pub fn huffman_encoder_handles_long_runs_test() -> Nil {
  // Mixed content that requires the encoder to emit literals and
  // length/distance pairs back to back.
  let payload = <<"abcdef":utf8, "abcdef":utf8, "abcdef":utf8, "xyz":utf8>>
  let assert Ok(compressed) = deflate.encode(bytes: payload)
  let assert Ok(restored) = deflate.decode(bytes: compressed)
  restored
  |> should.equal(payload)
}

fn repeat_byte(byte: Int, count: Int, acc: BitArray) -> BitArray {
  case count {
    0 -> acc
    _ -> repeat_byte(byte, count - 1, <<acc:bits, byte>>)
  }
}
