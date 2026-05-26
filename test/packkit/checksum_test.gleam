import gleeunit/should
import packkit/checksum

pub fn adler32_empty_test() -> Nil {
  checksum.adler32(<<>>)
  |> should.equal(1)
}

pub fn adler32_wikipedia_test() -> Nil {
  // Reference value from Wikipedia's Adler-32 article.
  checksum.adler32(<<"Wikipedia":utf8>>)
  |> should.equal(0x11E60398)
}

pub fn adler32_continue_matches_single_pass_test() -> Nil {
  let full = <<"The quick brown fox jumps over the lazy dog":utf8>>
  let prefix = <<"The quick brown fox ":utf8>>
  let suffix = <<"jumps over the lazy dog":utf8>>

  let direct = checksum.adler32(full)
  let chained = checksum.adler32_continue(checksum.adler32(prefix), suffix)

  direct
  |> should.equal(chained)
}

pub fn crc32_empty_test() -> Nil {
  checksum.crc32(<<>>)
  |> should.equal(0)
}

pub fn crc32_iso_3309_check_value_test() -> Nil {
  // The canonical ISO 3309 / IEEE 802.3 check value for "123456789".
  checksum.crc32(<<"123456789":utf8>>)
  |> should.equal(0xCBF43926)
}

pub fn crc64_xz_empty_test() -> Nil {
  // crc64_init XOR crc64_init = 0 for an empty input.  The result is
  // a `#(low_u32, high_u32)` pair to stay exact on the JS target.
  checksum.crc64_xz(<<>>)
  |> should.equal(#(0, 0))
}

pub fn crc64_xz_check_value_test() -> Nil {
  // The canonical CRC-64/XZ check value for "123456789" is
  // 0x995DC9BBDF1939FA, split into low / high 32-bit halves.
  checksum.crc64_xz(<<"123456789":utf8>>)
  |> should.equal(#(0xDF1939FA, 0x995DC9BB))
}

pub fn sha256_empty_test() -> Nil {
  // FIPS 180-4 test vector: SHA-256 of empty input is the canonical
  // e3b0c442... digest.
  checksum.sha256(<<>>)
  |> should.equal(<<
    0xE3, 0xB0, 0xC4, 0x42, 0x98, 0xFC, 0x1C, 0x14, 0x9A, 0xFB, 0xF4, 0xC8, 0x99,
    0x6F, 0xB9, 0x24, 0x27, 0xAE, 0x41, 0xE4, 0x64, 0x9B, 0x93, 0x4C, 0xA4, 0x95,
    0x99, 0x1B, 0x78, 0x52, 0xB8, 0x55,
  >>)
}

pub fn sha256_abc_test() -> Nil {
  // FIPS 180-4 Appendix B test vector for "abc".
  checksum.sha256(<<"abc":utf8>>)
  |> should.equal(<<
    0xBA, 0x78, 0x16, 0xBF, 0x8F, 0x01, 0xCF, 0xEA, 0x41, 0x41, 0x40, 0xDE, 0x5D,
    0xAE, 0x22, 0x23, 0xB0, 0x03, 0x61, 0xA3, 0x96, 0x17, 0x7A, 0x9C, 0xB4, 0x10,
    0xFF, 0x61, 0xF2, 0x00, 0x15, 0xAD,
  >>)
}

pub fn sha256_two_block_test() -> Nil {
  // The classic 56-byte input that forces an extra padding block
  // ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq").
  let input = <<
    "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq":utf8,
  >>
  checksum.sha256(input)
  |> should.equal(<<
    0x24, 0x8D, 0x6A, 0x61, 0xD2, 0x06, 0x38, 0xB8, 0xE5, 0xC0, 0x26, 0x93, 0x0C,
    0x3E, 0x60, 0x39, 0xA3, 0x3C, 0xE4, 0x59, 0x64, 0xFF, 0x21, 0x67, 0xF6, 0xEC,
    0xED, 0xD4, 0x19, 0xDB, 0x06, 0xC1,
  >>)
}

pub fn crc32_continue_matches_single_pass_test() -> Nil {
  let full = <<"The quick brown fox jumps over the lazy dog":utf8>>
  let prefix = <<"The quick brown fox ":utf8>>
  let suffix = <<"jumps over the lazy dog":utf8>>

  let direct = checksum.crc32(full)
  let chained = checksum.crc32_continue(checksum.crc32(prefix), suffix)

  direct
  |> should.equal(chained)
}

pub fn bzip2_crc32_check_value_test() -> Nil {
  // Block CRC produced by `printf 'hello' | bzip2 -1 -c`.
  checksum.bzip2_crc32(<<"hello":utf8>>)
  |> should.equal(0x1931653D)
}

pub fn crc32_xz_block_header_test() -> Nil {
  // xz block header pre-CRC bytes from a `printf 'hi' | xz -c` fixture.
  let header = <<
    0x04, 0xC0, 0x06, 0x02, 0x21, 0x01, 0x16, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00,
  >>
  checksum.crc32(header)
  |> should.equal(0x4CC2CB11)
}

// -- SHA-1 + HMAC-SHA1 + PBKDF2 test vectors --------------------------
//
// SHA-1 vectors are from FIPS 180-4 Appendix A; HMAC-SHA1 from
// RFC 2202 §3; PBKDF2-HMAC-SHA1 from RFC 6070 §2.  Pinning the
// official vectors here guards against subtle byte-order / padding
// bugs in the primitive that ZIP AE-x decryption depends on end-to-end.

pub fn sha1_empty_test() -> Nil {
  // FIPS 180-4 Appendix A, "" → da39a3ee5e6b4b0d3255bfef95601890afd80709
  checksum.sha1(data: <<>>)
  |> should.equal(<<
    0xDA, 0x39, 0xA3, 0xEE, 0x5E, 0x6B, 0x4B, 0x0D, 0x32, 0x55, 0xBF, 0xEF, 0x95,
    0x60, 0x18, 0x90, 0xAF, 0xD8, 0x07, 0x09,
  >>)
}

pub fn sha1_abc_test() -> Nil {
  // FIPS 180-4 Appendix A, "abc" → a9993e364706816aba3e25717850c26c9cd0d89d
  checksum.sha1(data: <<"abc":utf8>>)
  |> should.equal(<<
    0xA9, 0x99, 0x3E, 0x36, 0x47, 0x06, 0x81, 0x6A, 0xBA, 0x3E, 0x25, 0x71, 0x78,
    0x50, 0xC2, 0x6C, 0x9C, 0xD0, 0xD8, 0x9D,
  >>)
}

pub fn sha1_two_block_test() -> Nil {
  // Standard 448-bit (56-byte) message; exercises two SHA-1 blocks.
  checksum.sha1(data: <<
    "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq":utf8,
  >>)
  |> should.equal(<<
    0x84, 0x98, 0x3E, 0x44, 0x1C, 0x3B, 0xD2, 0x6E, 0xBA, 0xAE, 0x4A, 0xA1, 0xF9,
    0x51, 0x29, 0xE5, 0xE5, 0x46, 0x70, 0xF1,
  >>)
}

pub fn hmac_sha1_rfc2202_case_1_test() -> Nil {
  // RFC 2202 §3 test case 1.
  let key = <<
    0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B,
    0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B,
  >>
  let data = <<"Hi There":utf8>>
  checksum.hmac_sha1(key: key, data: data)
  |> should.equal(<<
    0xB6, 0x17, 0x31, 0x86, 0x55, 0x05, 0x72, 0x64, 0xE2, 0x8B, 0xC0, 0xB6, 0xFB,
    0x37, 0x8C, 0x8E, 0xF1, 0x46, 0xBE, 0x00,
  >>)
}

pub fn hmac_sha1_rfc2202_case_2_test() -> Nil {
  // RFC 2202 §3 test case 2 (short key + utf8 data).
  let key = <<"Jefe":utf8>>
  let data = <<"what do ya want for nothing?":utf8>>
  checksum.hmac_sha1(key: key, data: data)
  |> should.equal(<<
    0xEF, 0xFC, 0xDF, 0x6A, 0xE5, 0xEB, 0x2F, 0xA2, 0xD2, 0x74, 0x16, 0xD5, 0xF1,
    0x84, 0xDF, 0x9C, 0x25, 0x9A, 0x7C, 0x79,
  >>)
}

pub fn pbkdf2_hmac_sha1_rfc6070_case_1_test() -> Nil {
  // RFC 6070 §2 vector 1: P="password", S="salt", c=1, dkLen=20
  checksum.pbkdf2_hmac_sha1(
    password: <<"password":utf8>>,
    salt: <<"salt":utf8>>,
    iterations: 1,
    dk_len: 20,
  )
  |> should.equal(<<
    0x0C, 0x60, 0xC8, 0x0F, 0x96, 0x1F, 0x0E, 0x71, 0xF3, 0xA9, 0xB5, 0x24, 0xAF,
    0x60, 0x12, 0x06, 0x2F, 0xE0, 0x37, 0xA6,
  >>)
}

pub fn pbkdf2_hmac_sha1_rfc6070_case_2_test() -> Nil {
  // RFC 6070 §2 vector 2: P="password", S="salt", c=2, dkLen=20
  checksum.pbkdf2_hmac_sha1(
    password: <<"password":utf8>>,
    salt: <<"salt":utf8>>,
    iterations: 2,
    dk_len: 20,
  )
  |> should.equal(<<
    0xEA, 0x6C, 0x01, 0x4D, 0xC7, 0x2D, 0x6F, 0x8C, 0xCD, 0x1E, 0xD9, 0x2A, 0xCE,
    0x1D, 0x41, 0xF0, 0xD8, 0xDE, 0x89, 0x57,
  >>)
}

pub fn pbkdf2_hmac_sha1_rfc6070_case_4_test() -> Nil {
  // RFC 6070 §2 vector 4: c=4096 — bigger iteration count exercises
  // the inner loop carefully.
  checksum.pbkdf2_hmac_sha1(
    password: <<"password":utf8>>,
    salt: <<"salt":utf8>>,
    iterations: 4096,
    dk_len: 20,
  )
  |> should.equal(<<
    0x4B, 0x00, 0x79, 0x01, 0xB7, 0x65, 0x48, 0x9A, 0xBE, 0xAD, 0x49, 0xD9, 0x26,
    0xF7, 0x21, 0xD0, 0x65, 0xA4, 0x29, 0xC1,
  >>)
}
