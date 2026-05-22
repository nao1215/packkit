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
