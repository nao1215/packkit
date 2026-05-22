import gleeunit/should
import packkit/codec
import packkit/error
import packkit/lzw

pub fn codec_marker_test() -> Nil {
  lzw.codec()
  |> codec.name
  |> should.equal("lzw")
}

pub fn decode_hello_test() -> Nil {
  // `printf 'hello' | compress -c` produces this stream.
  let fixture = <<0x1F, 0x9D, 0x90, 0x68, 0xCA, 0xB0, 0x61, 0xF3, 0x06>>
  let assert Ok(plain) = lzw.decode(bytes: fixture)
  plain
  |> should.equal(<<"hello":utf8>>)
}

pub fn decode_repeated_byte_test() -> Nil {
  // `printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaa' | compress -c`.
  let fixture = <<
    0x1F, 0x9D, 0x90, 0x61, 0x02, 0x0A, 0x1C, 0x48, 0xB0, 0xA0, 0x41,
  >>
  let assert Ok(plain) = lzw.decode(bytes: fixture)
  plain
  |> should.equal(<<"aaaaaaaaaaaaaaaaaaaaaaaaaaaa":utf8>>)
}

pub fn decode_pangram_test() -> Nil {
  let fixture = <<
    0x1F, 0x9D, 0x90, 0x54, 0xD0, 0x94, 0x01, 0x11, 0xA7, 0x4E, 0x9A, 0x31, 0x6B,
    0x40, 0x88, 0x91, 0xF3, 0xE6, 0x8E, 0x1B, 0x10, 0x66, 0xDE, 0xE0, 0x01, 0xA1,
    0xA6, 0x4E, 0x1B, 0x38, 0x73, 0x40, 0xBC, 0xB1, 0x53, 0x46, 0x0E, 0x08, 0x3A,
    0x02, 0x41, 0xB0, 0x09, 0xA3, 0x27, 0x0F, 0x08, 0x32, 0x6F, 0xCE, 0x28, 0x00,
  >>
  let assert Ok(plain) = lzw.decode(bytes: fixture)
  plain
  |> should.equal(<<"The quick brown fox jumps over the lazy dog\n":utf8>>)
}

pub fn decode_rejects_missing_magic_test() -> Nil {
  lzw.decode(bytes: <<0x00, 0x00, 0x00>>)
  |> should.equal(
    Error(error.CodecInvalidData(message: "lzw stream missing 1F 9D magic")),
  )
}

pub fn roundtrip_short_text_test() -> Nil {
  let payload = <<"packkit lzw round trip":utf8>>
  let assert Ok(encoded) = lzw.encode(bytes: payload)
  let assert Ok(decoded) = lzw.decode(bytes: encoded)
  decoded
  |> should.equal(payload)
}

pub fn roundtrip_repeated_byte_test() -> Nil {
  let payload = repeat_byte(0x42, 512, <<>>)
  let assert Ok(encoded) = lzw.encode(bytes: payload)
  let assert Ok(decoded) = lzw.decode(bytes: encoded)
  decoded
  |> should.equal(payload)
}

pub fn roundtrip_alphabet_test() -> Nil {
  let payload = <<
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789":utf8,
  >>
  let assert Ok(encoded) = lzw.encode(bytes: payload)
  let assert Ok(decoded) = lzw.decode(bytes: encoded)
  decoded
  |> should.equal(payload)
}

pub fn roundtrip_empty_test() -> Nil {
  let assert Ok(encoded) = lzw.encode(bytes: <<>>)
  let assert Ok(decoded) = lzw.decode(bytes: encoded)
  decoded
  |> should.equal(<<>>)
}

fn repeat_byte(byte: Int, count: Int, acc: BitArray) -> BitArray {
  case count {
    0 -> acc
    _ -> repeat_byte(byte, count - 1, <<acc:bits, byte>>)
  }
}
