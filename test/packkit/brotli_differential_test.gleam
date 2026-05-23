//// Auto-generated brotli differential corpus.  See
//// `~/Desktop/gleam-dig-bug-packkit-20260523-200000/scripts/gen_brotli_fixtures.py`.
////
//// Each test feeds a brotli-CLI-compressed payload through
//// `packkit/brotli.decode` and asserts equality with the original
//// UTF-8 bytes.  Failures pinpoint the fixture name in the
//// gleeunit transcript so reducing to a minimal repro is trivial.

import gleam/bit_array
import gleeunit/should
import packkit/brotli

pub fn diff_all_a_1_test() -> Nil {
  let assert Ok(input) = bit_array.base16_decode("0F00806103")
  let expected = bit_array.from_string("a")
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_all_x_1_test() -> Nil {
  let assert Ok(input) = bit_array.base16_decode("0F00807803")
  let expected = bit_array.from_string("x")
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_all_a_2_test() -> Nil {
  let assert Ok(input) = bit_array.base16_decode("8F0080616103")
  let expected = bit_array.from_string("aa")
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_all_x_2_test() -> Nil {
  let assert Ok(input) = bit_array.base16_decode("8F0080787803")
  let expected = bit_array.from_string("xx")
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_all_a_9_test() -> Nil {
  let assert Ok(input) = bit_array.base16_decode("1F0800F825C262840000")
  let expected = bit_array.from_string("aaaaaaaaa")
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_all_x_9_test() -> Nil {
  let assert Ok(input) = bit_array.base16_decode("1F0800F825F062840000")
  let expected = bit_array.from_string("xxxxxxxxx")
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_all_a_15_test() -> Nil {
  let assert Ok(input) = bit_array.base16_decode("1F0E00F825C2028C0020")
  let expected = bit_array.from_string("aaaaaaaaaaaaaaa")
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_all_x_15_test() -> Nil {
  let assert Ok(input) = bit_array.base16_decode("1F0E00F825F0028C0020")
  let expected = bit_array.from_string("xxxxxxxxxxxxxxx")
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_all_a_100_test() -> Nil {
  let assert Ok(input) = bit_array.base16_decode("1F6300F825C202B140A003")
  let expected =
    bit_array.from_string(
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    )
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_all_x_100_test() -> Nil {
  let assert Ok(input) = bit_array.base16_decode("1F6300F825F002B140A003")
  let expected =
    bit_array.from_string(
      "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    )
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_all_a_1000_test() -> Nil {
  let assert Ok(input) = bit_array.base16_decode("1FE703F825C2A2B1402034")
  let expected =
    bit_array.from_string(
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    )
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_all_x_1000_test() -> Nil {
  let assert Ok(input) = bit_array.base16_decode("1FE703F825F0A2B1402034")
  let expected =
    bit_array.from_string(
      "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    )
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_abc_cycle_10_test() -> Nil {
  let assert Ok(input) = bit_array.base16_decode("1F1D00F825C3C4C6829B20A01A")
  let expected = bit_array.from_string("abcabcabcabcabcabcabcabcabcabc")
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_abcdefghij_cycle_10_test() -> Nil {
  let assert Ok(input) =
    bit_array.base16_decode("1F6300F845856340BC7C0480A1001494D3D97B")
  let expected =
    bit_array.from_string(
      "abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij",
    )
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_abc_cycle_50_test() -> Nil {
  let assert Ok(input) = bit_array.base16_decode("1F9500F825C3C4C642B320A0D1")
  let expected =
    bit_array.from_string(
      "abcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabc",
    )
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_abcdefghij_cycle_50_test() -> Nil {
  let assert Ok(input) =
    bit_array.base16_decode("1FF301F845856340BC7C0481A100A4A09CCEDE03")
  let expected =
    bit_array.from_string(
      "abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij",
    )
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_abc_cycle_500_test() -> Nil {
  let assert Ok(input) = bit_array.base16_decode("1FDB05F825C3C4C6C2B32060320D")
  let expected =
    bit_array.from_string(
      "abcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabc",
    )
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_abcdefghij_cycle_500_test() -> Nil {
  let assert Ok(input) =
    bit_array.base16_decode("1F8713F845856340BC7CC481A100380B00A09CCEDE03")
  let expected =
    bit_array.from_string(
      "abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij",
    )
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_ascii_alphabet_test() -> Nil {
  let assert Ok(input) =
    bit_array.base16_decode(
      "8F1E806162636465666768696A6B6C6D6E6F707172737475767778797A4142434445464748494A4B4C4D4E4F505152535455565758595A3031323334353637383903",
    )
  let expected =
    bit_array.from_string(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
    )
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_ascii_alphabet_x4_test() -> Nil {
  let assert Ok(input) =
    bit_array.base16_decode(
      "1FF700F88DD45A2DB7995B3CC63CC27AE7E0BC580756E30C15A309A691589436D6F910532EB5F531D73EF77D50DA58E7434CB9D4D6C75CFB5CF7F37E3F800813CAB890",
    )
  let expected =
    bit_array.from_string(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
    )
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_hello_world_test() -> Nil {
  let assert Ok(input) =
    bit_array.base16_decode("0F068048656C6C6F2C20576F726C642103")
  let expected = bit_array.from_string("Hello, World!")
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_the_quick_brown_fox_test() -> Nil {
  let assert Ok(input) =
    bit_array.base16_decode(
      "1FC101882C0E78D3D0955D9710BB172BA9CAD092CC8CAD415CE6F236C8199E9E0A7B830D387048206F24BD41A715CE1C1E27AA2938C279DAA7C1",
    )
  let expected =
    bit_array.from_string(
      "The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. ",
    )
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_json_small_test() -> Nil {
  let assert Ok(input) =
    bit_array.base16_decode(
      "1F4600F845B779FDBB3DA2F0F1FB5424024BE88DC0212778303D70F3C002D33A00034EE8C1FF707407049ACB03049D01198DAA9549E7B9DE4A3CFC01",
    )
  let expected =
    bit_array.from_string(
      "{\"name\":\"alice\",\"age\":30,\"name\":\"bob\",\"age\":25,\"name\":\"carol\",\"age\":35}",
    )
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_json_array_of_quoted_test() -> Nil {
  let assert Ok(input) =
    bit_array.base16_decode(
      "1F4500108CD462CD19EE04E5B6D4AF56D3C447079B1334592C5DE09003875BD60A10030B3C64E13759CAD278FC40D733302DD3C0503075AE476DF015B66FD55E2A",
    )
  let expected =
    bit_array.from_string(
      "[\"alpha\",\"beta\",\"gamma\",\"delta\",\"epsilon\",\"zeta\",\"eta\",\"theta\",\"iota\"]",
    )
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_json_full_test() -> Nil {
  let assert Ok(input) =
    bit_array.base16_decode(
      "1F9601408CC43826F14453C44110E0B652BF0CC3247D09DF48434C5287A56BEA26D8FF767FD2F6A0791E48D8064F30E040C7D46D5E7615F40D5C6E5AF2405F237AC8B50BC8B64A324216192C5DA1681DF27E4DA0747B1A2C09FC7270B3852010CE57CA2A1EE2C54D4705A66C454A2344DF13D64A52CAB9AD9E081C039C7F9A86F0BE634E32F0656CAABAA11ACEDF3043CB1ECE9290F32F3084292C35CE5649ACB2581021C78A58D45D101E20D6BDC8F19065C3B6AA2ADD4B0A73B6CE55B6C051D8B3391E96E2E3EF03",
    )
  let expected =
    bit_array.from_string(
      "{\"users\":[{\"name\":\"alice\",\"age\":30,\"email\":\"alice@example.com\",\"active\":true,\"score\":99.5},{\"name\":\"bob\",\"age\":25,\"email\":\"bob@example.com\",\"active\":false,\"score\":87.3},{\"name\":\"charlie\",\"age\":35,\"email\":\"charlie@example.com\",\"active\":true,\"score\":91.7}],\"timestamp\":\"2024-01-15T12:34:56Z\",\"version\":\"1.2.3-beta\",\"tags\":[\"api\",\"stable\",\"production\"],\"settings\":{\"timeout\":30000,\"retries\":5,\"verbose\":false}}",
    )
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_json_keys_only_test() -> Nil {
  let assert Ok(input) =
    bit_array.base16_decode(
      "1FA000F82D0EECC66E6FA01B1A94880CAF3EC4DC489A0A76FC5A13DC606CAC0D18193A215222636E70E855AFDA80830E6C170222BC1F8254A43A0306A729C49266ABE2E8764D9266B3C44D527E5FFF",
    )
  let expected =
    bit_array.from_string(
      "{\"a\":1,\"bb\":2,\"ccc\":3,\"dddd\":4,\"eeeee\":5,\"ffffff\":6,\"ggggggg\":7,\"hhhhhhhh\":8,\"iiiiiiiii\":9,\"jjjjjjjjjj\":10,\"kkkkkkkkkkk\":11,\"llllllllllll\":12,\"mmmmmmmmmmmmm\":13}",
    )
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_comma_after_quote_short_test() -> Nil {
  let assert Ok(input) =
    bit_array.base16_decode("0F09802261222C2262222C2263222C2264222C22652203")
  let expected = bit_array.from_string("\"a\",\"b\",\"c\",\"d\",\"e\"")
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_comma_after_quote_long_test() -> Nil {
  let assert Ok(input) =
    bit_array.base16_decode(
      "1F8000408D935CCD759EBA59D39E79AB5834D80F1F382E587472C0270CC0B36349CB8EE10138A81BF6BD4B169BD926C4C10C687A4B43DCBD5D8D4FEBD032807F95D3776631434BAA7426DE3AE60F88C647E6BF86008AB3676287C305",
    )
  let expected =
    bit_array.from_string(
      "\"alpha\",\"beta\",\"gamma\",\"delta\",\"epsilon\",\"zeta\",\"eta\",\"theta\",\"iota\",\"kappa\",\"lambda\",\"mu\",\"nu\",\"xi\",\"omicron\",\"pi\",\"rho\",\"sigma\"",
    )
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_brace_after_quote_test() -> Nil {
  let assert Ok(input) =
    bit_array.base16_decode(
      "1F2200F82D0E6C4723135B0792CDEC33B1D873C221720FA19DD00991E82B49308A04B618AECE2F",
    )
  let expected =
    bit_array.from_string("{\"a\":1}{\"b\":2}{\"c\":3}{\"d\":4}{\"e\":5}")
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_bracket_after_quote_test() -> Nil {
  let assert Ok(input) =
    bit_array.base16_decode(
      "1F2600F89D07768C83443538DC1B2FB6747008C4FB552C5D21529A6414003C905AF49C0F",
    )
  let expected =
    bit_array.from_string(
      "[\"a\",\"b\",\"c\"][\"d\",\"e\",\"f\"][\"g\",\"h\",\"i\"]",
    )
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_code_like_test() -> Nil {
  let assert Ok(input) =
    bit_array.base16_decode(
      "1F5100009C0576E33231C295A70299F52E0B7470A4D30A427E90A6975A462C6F4F2AB0EC24CA9B1C38E49CCF74D21688A75E5A1C29987B71146CCE5DA688847DAD8C264E2B1A29",
    )
  let expected =
    bit_array.from_string(
      "function foo(x, y) {\n  return x + y * 2;\n}\nfunction bar(a, b) {\n  return a / b;\n}\n",
    )
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_random_ascii_50_test() -> Nil {
  let assert Ok(input) =
    bit_array.base16_decode(
      "8F188034236452413B404A4E24747866227A2351665409323132754B464E365B7C4477422B2C4F2D534B5B32722A4B2D3F5B27725803",
    )
  let expected =
    bit_array.from_string(
      "4#dRA;@JN$txf\"z#QfT\t212uKFN6[|DwB+,O-SK[2r*K-?['rX",
    )
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}

pub fn diff_random_ascii_200_test() -> Nil {
  let assert Ok(input) =
    bit_array.base16_decode(
      "1FC700F865609E790A1DC00D144CC285084290AF5E139C519C2545FDDFAD3837CBA33BB050F6CDADD1033CC9B6F7DE6EBAF290AF2E325A70D58AD66EE19FCA8ADDDDDD372347FC918C0506811D80C4C1A949264EFD676FD6D1AB82982EA215AAAD1DAB9EFE678046C22B775111341D2B27FE7879A5549DEB6E4518B5C0E27C85F972E9E4265DDA2D8D363B73970A37694346165B2193EB90765DE53CD75B64A3D16139552BE6AF61A5BEE9968F6E8793153470CDAA19802A01",
    )
  let expected =
    bit_array.from_string(
      "@*TtG)3PeH,2~\\S8khp:?g/nXl3]\t;HZ<vZX9N\u{000B}=V,'1@iYDUuB}0(,\\mv=e$a*p$E?Uu?m\t\rF\nd4$Gq^x]e[2T+,JP S%Z1pT;^{_ CBi:P/+12!RG~\"Ri/T8j\\S+aY\nPfi!=MJHkJQmh3Z(e:QOu-k$Cgl+KM[$6V0);tuCk1&B.IUPNtB/Vk\\Rp:78(+1\nj(0K\t%Q",
    )
  brotli.decode(bytes: input)
  |> should.equal(Ok(expected))
}
