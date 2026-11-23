import gleam/bit_array
import gleeunit/should
import packkit
import packkit/codec
import packkit/internal/zlib

pub fn decode_python_hello_test() -> Nil {
  let compressed = <<
    0x78,
    0x9C,
    0xCB,
    0x48,
    0xCD,
    0xC9,
    0xC9,
    0x07,
    0x00,
    0x06,
    0x2C,
    0x02,
    0x15,
  >>
  let assert Ok(plain) = packkit.decompress(compressed, with: codec.Zlib)
  plain
  |> should.equal(<<"hello":utf8>>)
}

pub fn decode_python_lorem_test() -> Nil {
  let compressed = <<
    0x78, 0x9C, 0x05, 0xC1, 0x81, 0x09, 0x40, 0x21, 0x08, 0x05, 0xC0, 0x55, 0xDE,
    0x00, 0xD1, 0x24, 0x7F, 0x89, 0x30, 0x89, 0x07, 0x99, 0xA1, 0xB6, 0xFF, 0xBF,
    0xFB, 0x3C, 0xD4, 0xC0, 0x9B, 0xCF, 0x30, 0x7D, 0x7B, 0x20, 0x59, 0x18, 0xA6,
    0xD5, 0x20, 0x7E, 0x52, 0xA5, 0xB4, 0x5E, 0x60, 0x4C, 0x5E, 0xA6, 0xF0, 0x2C,
    0xE8, 0x66, 0xF5, 0x1F, 0x55, 0x03, 0x14, 0xF7,
  >>
  let assert Ok(plain) = packkit.decompress(compressed, with: codec.Zlib)
  bit_array.to_string(plain)
  |> should.equal(Ok("Lorem ipsum dolor sit amet, consectetur adipiscing elit."))
}

pub fn roundtrip_with_packkit_encoder_test() -> Nil {
  let payload = <<"zlib stored-block roundtrip":utf8>>
  let assert Ok(compressed) = zlib.encode(bytes: payload)
  let assert Ok(restored) = packkit.decompress(compressed, with: codec.Zlib)
  restored
  |> should.equal(payload)
}

pub fn rejects_garbage_test() -> Nil {
  case packkit.decompress(<<0x00, 0x00>>, with: codec.Zlib) {
    Error(codec.InvalidData(_)) -> Nil
    _ -> should.fail()
  }
}

pub fn decode_rejects_preset_dictionary_test() -> Nil {
  // A zlib stream with FDICT set (FLG 0xBB) and a DICT_ID: packkit does
  // not support preset dictionaries and says so.
  let stream = <<0x78, 0xBB, 0x00, 0x62, 0x00, 0x62, 0x03, 0x00>>
  packkit.decompress(stream, with: codec.Zlib)
  |> should.equal(Error(codec.DictionaryRequired))
}
