//// Tripwires for known bzip2 round-trip bugs discovered via the
//// metamorphic suite (gleam-dig-bug session, 2026-05-23).
////
//// Each test asserts the CURRENT (wrong) behavior so we notice the
//// moment a fix or regression flips it.  When a fix is pushed, update
//// the asserted error to the expected `Ok(...)` round-trip.

import gleeunit/should
import packkit/bzip2
import packkit/error

/// `bzip2.encode(<<0x61, 0x61, …>>)` (1000 `a` bytes) produces a stream
/// that fails its own block CRC validation on `bzip2.decode`.  Short
/// runs (`"a" * 100`) round-trip cleanly, so the trigger is
/// length-dependent and probably an RLE1 / BWT / CRC scope mismatch
/// between encoder and decoder.
pub fn bug3_repeated_a_1k_test() -> Nil {
  let payload = byte_repeat(0x61, 1000)
  let assert Ok(encoded) = bzip2.encode(bytes: payload)
  bzip2.decode(bytes: encoded)
  |> should.equal(
    Error(error.CodecInvalidData(message: "bzip2 block CRC mismatch")),
  )
}

/// Same symptom on 1000 zero bytes — same root cause as Bug #3.
pub fn bug3_zeros_1k_test() -> Nil {
  let payload = byte_repeat(0x00, 1000)
  let assert Ok(encoded) = bzip2.encode(bytes: payload)
  bzip2.decode(bytes: encoded)
  |> should.equal(
    Error(error.CodecInvalidData(message: "bzip2 block CRC mismatch")),
  )
}

fn byte_repeat(byte: Int, count: Int) -> BitArray {
  byte_repeat_loop(byte, count, <<>>)
}

fn byte_repeat_loop(byte: Int, count: Int, acc: BitArray) -> BitArray {
  case count {
    n if n <= 0 -> acc
    _ -> byte_repeat_loop(byte, count - 1, <<acc:bits, byte>>)
  }
}
