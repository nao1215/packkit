//// Panic-free fuzz tests for `packkit/seven_z.decode/1`.
////
//// Property: every input — well-formed or arbitrary garbage —
//// makes `seven_z.decode/1` return a `Result` (never panic,
//// never hang).  We don't assert the shape of the error;
//// surviving the call without a crash IS the property.

import gleam/bit_array
import packkit/seven_z

pub fn fuzz_seven_z_empty_test() -> Nil {
  let _ = seven_z.decode(bytes: <<>>)
  Nil
}

pub fn fuzz_seven_z_single_zero_test() -> Nil {
  let _ = seven_z.decode(bytes: <<0x00>>)
  Nil
}

pub fn fuzz_seven_z_single_ff_test() -> Nil {
  let _ = seven_z.decode(bytes: <<0xFF>>)
  Nil
}

pub fn fuzz_seven_z_partial_signature_test() -> Nil {
  // First three bytes of the 7z signature but truncated — must not panic
  // on the boundary check.
  let _ = seven_z.decode(bytes: <<0x37, 0x7A, 0xBC>>)
  Nil
}

pub fn fuzz_seven_z_full_signature_only_test() -> Nil {
  // Full signature with no rest — header version, CRC, and trailer
  // offsets all missing.
  let _ = seven_z.decode(bytes: <<0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C>>)
  Nil
}

pub fn fuzz_seven_z_all_zeros_32_test() -> Nil {
  let assert Ok(payload) =
    bit_array.base16_decode(
      "0000000000000000000000000000000000000000000000000000000000000000",
    )
  let _ = seven_z.decode(bytes: payload)
  Nil
}

pub fn fuzz_seven_z_all_ff_32_test() -> Nil {
  let assert Ok(payload) =
    bit_array.base16_decode(
      "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
    )
  let _ = seven_z.decode(bytes: payload)
  Nil
}

pub fn fuzz_seven_z_signature_garbage_test() -> Nil {
  // Real signature followed by 64 random bytes.
  let assert Ok(payload) =
    bit_array.base16_decode(
      "377ABCAF271C0004DE7374EF0634215A02948D5CBADC072B7274EF063421DDDD5A02948D5CBADC072BDE7374EF0634215A02948D5CBADC072BDE7374EF063421",
    )
  let _ = seven_z.decode(bytes: payload)
  Nil
}

pub fn fuzz_seven_z_alternating_test() -> Nil {
  let assert Ok(payload) =
    bit_array.base16_decode(
      "55AA55AA55AA55AA55AA55AA55AA55AA55AA55AA55AA55AA55AA55AA55AA55AA",
    )
  let _ = seven_z.decode(bytes: payload)
  Nil
}

pub fn fuzz_seven_z_counter_256_test() -> Nil {
  let assert Ok(payload) =
    bit_array.base16_decode(
      "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F202122232425262728292A2B2C2D2E2F303132333435363738393A3B3C3D3E3F404142434445464748494A4B4C4D4E4F505152535455565758595A5B5C5D5E5F606162636465666768696A6B6C6D6E6F707172737475767778797A7B7C7D7E7F808182838485868788898A8B8C8D8E8F909192939495969798999A9B9C9D9E9FA0A1A2A3A4A5A6A7A8A9AAABACADAEAFB0B1B2B3B4B5B6B7B8B9BABBBCBDBEBFC0C1C2C3C4C5C6C7C8C9CACBCCCDCECFD0D1D2D3D4D5D6D7D8D9DADBDCDDDEDFE0E1E2E3E4E5E6E7E8E9EAEBECEDEEEFF0F1F2F3F4F5F6F7F8F9FAFBFCFDFEFF",
    )
  let _ = seven_z.decode(bytes: payload)
  Nil
}
