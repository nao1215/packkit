import gleam/bit_array
import gleeunit/should
import packkit/error
import packkit/zlib

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
  let assert Ok(plain) = zlib.decode(bytes: compressed)
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
  let assert Ok(plain) = zlib.decode(bytes: compressed)
  bit_array.to_string(plain)
  |> should.equal(Ok("Lorem ipsum dolor sit amet, consectetur adipiscing elit."))
}

pub fn roundtrip_with_packkit_encoder_test() -> Nil {
  let payload = <<"zlib stored-block roundtrip":utf8>>
  let assert Ok(compressed) = zlib.encode(bytes: payload)
  let assert Ok(restored) = zlib.decode(bytes: compressed)
  restored
  |> should.equal(payload)
}

pub fn rejects_garbage_test() -> Nil {
  case zlib.decode(bytes: <<0x00, 0x00>>) {
    Error(error.CodecInvalidData(_)) -> Nil
    _ -> should.fail()
  }
}

pub fn decode_with_dictionary_round_trips_test() -> Nil {
  // The dictionary path is now reachable from the public surface:
  // `encode_with_dictionary` produces a stream that carries the
  // DICT_ID, and `decode_with_dictionary` verifies and decodes it.
  let payload = <<"dictionary round trip":utf8>>
  let dict = <<"shared-secret-dictionary":utf8>>
  let assert Ok(stream) =
    zlib.encode_with_dictionary(bytes: payload, dictionary: dict)
  let assert Ok(restored) =
    zlib.decode_with_dictionary(bytes: stream, dictionary: dict)
  restored
  |> should.equal(payload)
}

pub fn decode_without_supplied_dictionary_errors_test() -> Nil {
  // When FDICT is set but the caller did not pass a dictionary the
  // decoder must surface `CodecDictionaryRequired` so the caller
  // knows what to fix.
  let dict = <<"a":utf8>>
  let assert Ok(stream) =
    zlib.encode_with_dictionary(bytes: <<"x":utf8>>, dictionary: dict)
  case zlib.decode(bytes: stream) {
    Error(error.CodecDictionaryRequired(name)) ->
      name
      |> should.equal("zlib")
    _ -> should.fail()
  }
}

pub fn decode_with_wrong_dictionary_errors_test() -> Nil {
  // A mismatched dictionary must trigger `CodecDictionaryMismatch`
  // instead of silently decoding into garbage.
  let assert Ok(stream) =
    zlib.encode_with_dictionary(bytes: <<"y":utf8>>, dictionary: <<
      "correct":utf8,
    >>)
  case
    zlib.decode_with_dictionary(bytes: stream, dictionary: <<"wrong":utf8>>)
  {
    Error(error.CodecDictionaryMismatch(name)) ->
      name
      |> should.equal("zlib")
    _ -> should.fail()
  }
}
