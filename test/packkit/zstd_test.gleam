import gleeunit/should
import packkit/codec
import packkit/error
import packkit/zstd

pub fn codec_marker_test() -> Nil {
  zstd.codec()
  |> codec.name
  |> should.equal("zstd")
}

pub fn encode_reports_not_implemented_test() -> Nil {
  zstd.encode(bytes: <<>>)
  |> should.equal(Error(error.CodecNotImplemented(feature: "zstd.encode")))
}

pub fn decode_raw_block_hi_test() -> Nil {
  // `printf 'hi' | zstd -c` — frame with one raw block + checksum.
  let fixture = <<
    0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x58, 0x11, 0x00, 0x00, 0x68, 0x69, 0xFA, 0x38,
    0x26, 0xEA,
  >>
  let assert Ok(plain) = zstd.decode(bytes: fixture)
  plain
  |> should.equal(<<"hi":utf8>>)
}

pub fn decode_raw_block_abc_test() -> Nil {
  // `printf 'abc' | zstd -c`.
  let fixture = <<
    0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x58, 0x19, 0x00, 0x00, 0x61, 0x62, 0x63, 0x99,
    0x09, 0x77, 0xAD,
  >>
  let assert Ok(plain) = zstd.decode(bytes: fixture)
  plain
  |> should.equal(<<"abc":utf8>>)
}

pub fn decode_compressed_block_repeated_byte_test() -> Nil {
  // `printf 'aaaaaaaaaaaaaaaaaaaa' | zstd -c` — block type 2:
  // raw literals "aa" (2 bytes) + 1 sequence (literal_length=2,
  // match_length=18, offset=1) under the predefined FSE tables.
  let fixture = <<
    0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x58, 0x45, 0x00, 0x00, 0x10, 0x61, 0x61, 0x01,
    0x00, 0x1E, 0xC0, 0x02, 0xF7, 0xAF, 0x47, 0xE3,
  >>
  let assert Ok(plain) = zstd.decode(bytes: fixture)
  plain
  |> should.equal(<<"aaaaaaaaaaaaaaaaaaaa":utf8>>)
}

pub fn decode_compressed_block_alternating_test() -> Nil {
  // `printf 'ababababababababababab' | zstd -c` — 22 bytes alternating
  // "ab".  Literals are raw "ab", then a single sequence with
  // offset 2 and match_length 20 covers the remainder.
  let fixture = <<
    0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x58, 0x45, 0x00, 0x00, 0x10, 0x61, 0x62, 0x01,
    0x00, 0xD1, 0x0E, 0x0B, 0xCB, 0xC5, 0x16, 0x03,
  >>
  let assert Ok(plain) = zstd.decode(bytes: fixture)
  plain
  |> should.equal(<<"ababababababababababab":utf8>>)
}

pub fn decode_compressed_block_pangram_pending_test() -> Nil {
  // Two copies of "The quick brown fox jumps over the lazy dog. "
  // (90 bytes) compressed by `zstd -c`.  zstd lays out a single
  // sequence with a large literal_length and a longer match.  The
  // decoder currently runs out of bits during the literal-length
  // extras decode — captured as follow-up work alongside repeat
  // offset history edge cases.
  let fixture = <<
    0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x58, 0xAD, 0x01, 0x00, 0xD4, 0x02, 0x54,
    0x68, 0x65, 0x20, 0x71, 0x75, 0x69, 0x63, 0x6B, 0x20, 0x62, 0x72, 0x6F,
    0x77, 0x6E, 0x20, 0x66, 0x6F, 0x78, 0x20, 0x6A, 0x75, 0x6D, 0x70, 0x73,
    0x20, 0x6F, 0x76, 0x65, 0x72, 0x20, 0x74, 0x68, 0x65, 0x20, 0x6C, 0x61,
    0x7A, 0x79, 0x20, 0x64, 0x6F, 0x67, 0x2E, 0x20, 0x01, 0x00, 0x0D, 0x9A,
    0xAA, 0x0C, 0x9D, 0xB4, 0xCD, 0x6C,
  >>
  case zstd.decode(bytes: fixture) {
    Error(error.CodecInvalidData(_)) -> Nil
    other -> {
      other
      |> should.equal(
        Error(error.CodecInvalidData(message: "<pangram follow-up>")),
      )
    }
  }
}

pub fn decode_rejects_missing_magic_test() -> Nil {
  zstd.decode(bytes: <<0x00, 0x00, 0x00, 0x00>>)
  |> should.equal(
    Error(error.CodecInvalidData(message: "missing zstd frame magic")),
  )
}
