//// Tripwires for known LZW round-trip bugs discovered via the
//// metamorphic suite (gleam-dig-bug session, 2026-05-23).
////
//// Each test asserts the CURRENT (wrong) behavior so we notice the
//// moment a fix or regression flips it.  When fixed, replace the
//// expected `Ok(corrupted)` assertion with `Ok(original)`.

import gleam/bit_array
import gleam/bool
import gleeunit/should
import packkit/lzw

/// `lzw.decode(lzw.encode(bytes(0..255)))` injects an extra `0` byte
/// between positions 254 and 255 — the round trip is `[0, 1, …, 254,
/// 255]` → encode → decode → `[0, 1, …, 254, 0, 255]`.  Trigger is
/// the 9→10-bit code-width grow that lands right at the end of the
/// initial 256-entry dictionary; either the encoder pads to a byte
/// boundary the decoder doesn't expect or vice versa.
pub fn bug4_lzw_byte_range_inserts_extra_zero_test() -> Nil {
  let payload = byte_range(0, 256, <<>>)
  let assert Ok(encoded) = lzw.encode(bytes: payload)
  let expected_corrupted =
    bit_array.concat([byte_range(0, 255, <<>>), <<0, 255>>])
  lzw.decode(bytes: encoded)
  |> should.equal(Ok(expected_corrupted))
}

fn byte_range(from: Int, until: Int, acc: BitArray) -> BitArray {
  use <- bool.guard(when: from >= until, return: acc)
  byte_range(from + 1, until, <<acc:bits, from>>)
}
