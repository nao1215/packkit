import gleam/bit_array
import gleam/string
import gleeunit/should
import packkit/codec
import packkit/error
import packkit/zstd

pub fn frame_header_fcs_one_byte_test() -> Nil {
  // Single_Segment + 1-byte FCS for sizes < 256.
  let assert Ok(header) = zstd.frame_header_for_size(7)
  header
  |> should.equal(<<0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x07>>)
}

pub fn frame_header_fcs_two_byte_test() -> Nil {
  // 2-byte FCS, stored as `size - 256` little-endian (RFC 8478 §3.1.1.1.2).
  // 1024 - 256 = 768 = 0x0300.
  let assert Ok(header) = zstd.frame_header_for_size(1024)
  header
  |> should.equal(<<0x28, 0xB5, 0x2F, 0xFD, 0x60, 768:size(16)-little>>)
}

pub fn frame_header_fcs_four_byte_boundary_test() -> Nil {
  // 0xFFFFFFFF (max 32-bit FCS) → uses the 4-byte FCS variant.
  let assert Ok(header) = zstd.frame_header_for_size(0xFFFFFFFF)
  header
  |> should.equal(<<
    0x28,
    0xB5,
    0x2F,
    0xFD,
    0xA0,
    0xFFFFFFFF:size(32)-little,
  >>)
}

pub fn frame_header_fcs_eight_byte_low_test() -> Nil {
  // 2^32 — just above the 4-byte FCS range, smallest 8-byte FCS value.
  // Regression for the bug where the encoder packed the value into the
  // low 32 bits and a literal 0 into the high 32, silently truncating
  // any payload >= 4 GiB to its low 32 bits.
  let assert Ok(header) = zstd.frame_header_for_size(0x1_0000_0000)
  header
  |> should.equal(<<
    0x28,
    0xB5,
    0x2F,
    0xFD,
    0xE0,
    0:size(32)-little,
    1:size(32)-little,
  >>)
}

pub fn frame_header_fcs_eight_byte_high_test() -> Nil {
  // Mixed low/high 32-bit halves: 0xAB_CDEF_0001 →
  //   lo = 0xCDEF_0001, hi = 0x000000AB.  This proves both halves are
  //   written separately and at the right position.  Stays under
  //   2^53 so the test is exact on both Erlang and JavaScript
  //   targets (JS numbers cannot represent values past 2^53).
  let assert Ok(header) = zstd.frame_header_for_size(0xAB_CDEF_0001)
  header
  |> should.equal(<<
    0x28,
    0xB5,
    0x2F,
    0xFD,
    0xE0,
    0xCDEF_0001:size(32)-little,
    0xAB:size(32)-little,
  >>)
}

pub fn codec_marker_test() -> Nil {
  zstd.codec()
  |> codec.name
  |> should.equal("zstd")
}

pub fn encode_roundtrip_hi_test() -> Nil {
  let payload = <<"hi":utf8>>
  let assert Ok(encoded) = zstd.encode(bytes: payload)
  let assert Ok(decoded) = zstd.decode(bytes: encoded)
  decoded
  |> should.equal(payload)
}

pub fn encode_roundtrip_pangram_test() -> Nil {
  let payload = <<"The quick brown fox jumps over the lazy dog.":utf8>>
  let assert Ok(encoded) = zstd.encode(bytes: payload)
  let assert Ok(decoded) = zstd.decode(bytes: encoded)
  decoded
  |> should.equal(payload)
}

pub fn encode_roundtrip_512_test() -> Nil {
  // Use a 512-byte payload to exercise the 2-byte FCS path.
  let payload = repeat_byte(0x41, 512, <<>>)
  let assert Ok(encoded) = zstd.encode(bytes: payload)
  let assert Ok(decoded) = zstd.decode(bytes: encoded)
  decoded
  |> should.equal(payload)
}

fn repeat_byte(byte: Int, count: Int, acc: BitArray) -> BitArray {
  case count {
    0 -> acc
    _ -> repeat_byte(byte, count - 1, <<acc:bits, byte>>)
  }
}

fn repeat_text(text: String, count: Int) -> BitArray {
  repeat_text_loop(text, count, <<>>)
}

fn repeat_text_loop(text: String, count: Int, acc: BitArray) -> BitArray {
  case count {
    0 -> acc
    _ -> repeat_text_loop(text, count - 1, <<acc:bits, text:utf8>>)
  }
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

pub fn decode_compressed_repeating_short_match_test() -> Nil {
  // 50 copies of "hello world " (600 bytes) → `zstd -3` packs the
  // whole stream into one short literal block and a single
  // sequence with a large match-length.  Useful regression
  // coverage for the predefined ML mapping in the ml_base(40)+
  // range that the predefined_match_length() fix unblocked.
  let fixture = <<
    0x28, 0xB5, 0x2F, 0xFD, 0x64, 0x58, 0x01, 0x9D, 0x00, 0x00, 0x60, 0x68, 0x65,
    0x6C, 0x6C, 0x6F, 0x20, 0x77, 0x6F, 0x72, 0x6C, 0x64, 0x20, 0x01, 0x00, 0x49,
    0x5E, 0x95, 0x24, 0xDE, 0x82, 0x7E, 0x8E,
  >>
  let assert Ok(plain) = zstd.decode(bytes: fixture)
  let expected = repeat_text("hello world ", 50)
  plain
  |> should.equal(expected)
}

pub fn decode_compressed_repeating_long_match_test() -> Nil {
  // 1000 copies of "abc" (3000 bytes) → `zstd -3` ends up with a
  // huge match-length that lands in the ml_code 44+ region.
  let fixture = <<
    0x28, 0xB5, 0x2F, 0xFD, 0x64, 0xB8, 0x0A, 0x55, 0x00, 0x00, 0x18, 0x61, 0x62,
    0x63, 0x01, 0x00, 0xB2, 0xD3, 0x77, 0x43, 0xC6, 0x03, 0x49, 0x84,
  >>
  let assert Ok(plain) = zstd.decode(bytes: fixture)
  let expected = repeat_text("abc", 1000)
  plain
  |> should.equal(expected)
}

pub fn decode_compressed_block_pangram_test() -> Nil {
  // "The quick brown fox jumps over the lazy dog. " followed by a
  // second copy without the trailing space (89 bytes total) as
  // emitted by `zstd -c`.  Previously this surfaced as a typed
  // CodecInvalidData because the predefined ML distribution was
  // wrong by two cells (-1 placeholders for codes 46 and 47 were
  // missing) which shifted every state→code mapping past code 36
  // by one.  With the ML_defaultNorm fix pulled into
  // [internal/fse.gleam](src/packkit/internal/fse.gleam),
  // the decoder reproduces the original pangram byte-for-byte.
  let fixture = <<
    0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x58, 0xAD, 0x01, 0x00, 0xD4, 0x02, 0x54, 0x68,
    0x65, 0x20, 0x71, 0x75, 0x69, 0x63, 0x6B, 0x20, 0x62, 0x72, 0x6F, 0x77, 0x6E,
    0x20, 0x66, 0x6F, 0x78, 0x20, 0x6A, 0x75, 0x6D, 0x70, 0x73, 0x20, 0x6F, 0x76,
    0x65, 0x72, 0x20, 0x74, 0x68, 0x65, 0x20, 0x6C, 0x61, 0x7A, 0x79, 0x20, 0x64,
    0x6F, 0x67, 0x2E, 0x20, 0x01, 0x00, 0x0D, 0x9A, 0xAA, 0x0C, 0x9D, 0xB4, 0xCD,
    0x6C,
  >>
  let assert Ok(plain) = zstd.decode(bytes: fixture)
  plain
  |> should.equal(<<
    "The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog.":utf8,
  >>)
}

pub fn decode_rejects_missing_magic_test() -> Nil {
  zstd.decode(bytes: <<0x00, 0x00, 0x00, 0x00>>)
  |> should.equal(
    Error(error.CodecInvalidData(message: "missing zstd frame magic")),
  )
}

pub fn treeless_literals_without_prior_tree_is_invalid_data_test() -> Nil {
  // Treeless literals blocks (block_type = 3) reuse the previous
  // block's Huffman tree.  When the first block of a frame
  // declares treeless literals there's no prior tree to reuse,
  // so the decoder must surface a typed CodecInvalidData error
  // mentioning treeless.  Build a minimal compressed block with
  // literals_section_header byte = (block_type 3 | size_format 0
  // << 2) = 0x03 then garbage.
  let block_payload = <<0x03, 0x00, 0x00, 0x00>>
  let block_size = bit_array.byte_size(block_payload)
  let block_header_int = 1 + 4 + { block_size * 8 }
  let block_header = <<block_header_int:size(24)-little>>
  let frame =
    bit_array.concat([
      <<0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x01>>,
      block_header,
      block_payload,
    ])

  case zstd.decode(bytes: frame) {
    Error(error.CodecInvalidData(message: message)) ->
      case string.contains(does: message, contain: "treeless") {
        True -> Nil
        False -> should.fail()
      }
    _ -> should.fail()
  }
}

pub fn decode_multi_frame_concatenated_test() -> Nil {
  // `zstd` decoders are required to walk through any number of
  // concatenated frames (RFC 8478 §3.1).  Build a two-frame fixture
  // with our own encoder and prove the decoder catenates the
  // payloads.
  let assert Ok(f1) = zstd.encode(bytes: <<"first-frame-payload":utf8>>)
  let assert Ok(f2) = zstd.encode(bytes: <<"-second-frame-payload":utf8>>)
  let combined = bit_array.concat([f1, f2])
  let assert Ok(plain) = zstd.decode(bytes: combined)
  plain
  |> should.equal(<<"first-frame-payload-second-frame-payload":utf8>>)
}

pub fn decode_real_zstd_huffman_literals_fixture_test() -> Nil {
  // 300-byte payload of random characters from a 16-symbol
  // alphabet generated with:
  //   python3 -c "import random; random.seed(99); chars=list('abcdefghijklmnop'); \
  //     import sys; sys.stdout.buffer.write(''.join(random.choices(chars, k=300)).encode())" \
  //     | zstd -1 -c
  // The compressed block uses FSE-weight Huffman literals + 4
  // streams (size_format=1, the common case for real `zstd -3`+
  // output).  Asserting the decoder returns the exact 300 byte
  // payload validates both the FSE weight reader and the
  // 4-stream jump-table walker.
  let fixture = <<
    0x28, 0xB5, 0x2F, 0xFD, 0x64, 0x2C, 0x00, 0x75, 0x05, 0x00, 0xC6, 0x92, 0x2A,
    0x0B, 0xD0, 0x0F, 0x24, 0x49, 0x92, 0x24, 0xC9, 0x07, 0x00, 0x28, 0x0F, 0x26,
    0x00, 0x26, 0x00, 0x26, 0x00, 0x22, 0x61, 0xB9, 0xD9, 0xE2, 0x5B, 0x6C, 0x34,
    0xC0, 0x83, 0x05, 0x14, 0x16, 0x7D, 0x00, 0xFA, 0x9F, 0x2C, 0x3E, 0xF5, 0xE9,
    0x87, 0x3F, 0x40, 0x76, 0x8C, 0x5F, 0xAD, 0xA2, 0x56, 0x3E, 0x69, 0xF7, 0xA8,
    0x46, 0x3C, 0x32, 0x16, 0xD5, 0xD3, 0xAB, 0x2A, 0x3A, 0xBF, 0x5A, 0x6E, 0xA7,
    0x9F, 0x4A, 0xA9, 0xE6, 0xE4, 0xC8, 0xED, 0x48, 0x7F, 0xC1, 0x34, 0xCA, 0xB3,
    0x4D, 0xAA, 0x74, 0xB6, 0xEE, 0x51, 0x66, 0x6D, 0x03, 0x49, 0x21, 0x1D, 0xCD,
    0x8C, 0x23, 0x12, 0x05, 0x90, 0x62, 0xA9, 0x98, 0x5B, 0x57, 0x70, 0x13, 0x72,
    0xEE, 0xE7, 0x6D, 0x9E, 0x44, 0xF2, 0xB6, 0x7D, 0x22, 0x27, 0xC6, 0xCF, 0x94,
    0x8F, 0x65, 0x9F, 0x14, 0x30, 0xCC, 0x9A, 0x78, 0xBB, 0x73, 0x2C, 0xAB, 0x04,
    0x18, 0x16, 0xD0, 0x55, 0x95, 0x15, 0x16, 0xC4, 0xFE, 0x42, 0x06, 0x55, 0xDC,
    0xDE, 0xD1, 0x7C, 0xC3, 0xA1, 0x06, 0xFB, 0x17, 0x32, 0x5A, 0x50, 0xC9, 0xB9,
    0x2D, 0xCA, 0x21, 0xBD, 0x1A, 0xAD, 0x8B, 0x83, 0x45, 0x12, 0x6C, 0x7B, 0xC2,
    0x13, 0x00, 0xE8, 0x6F, 0xD7, 0x2B,
  >>
  let expected = <<
    "gdcdmegkiphgjdofgkcknfpimhgeadpihojpfdocmjppkaahnbgbeafidmadegmflocnjljgbccccdimmnbncbejadgnggfboolghekkenldmkdembhpeionmioeogkjekjpkhgofklpdkckklndnfgbiaeklcmhdllhijkmmdabejpgfipjempmgchcchnlgpceejognohoohcbdhafhfljikjgcjaafdmchlgmbcefidilknbklncbmkcnljmjfafkdcbhplagkbmdhmnbnonmffagecpomebgbfjfffna":utf8,
  >>
  let assert Ok(plain) = zstd.decode(bytes: fixture)
  plain
  |> should.equal(expected)
}
