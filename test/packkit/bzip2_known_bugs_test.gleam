//// Regression tests for the bzip2 RLE1 encoder off-by-one bug
//// (discovered 2026-05-23 via the metamorphic suite; root-caused and
//// fixed 2026-05-23 via the gleam-oss-test packkit UX session).
////
//// Bug summary: when an input had ≥259 of the same byte in a row,
//// `rle1_loop` closed the maximum-length run by writing BOTH the
//// count byte 255 (representing 4 + 255 = 259 bytes) AND the current
//// input byte as raw — emitting one extra logical byte vs. what the
//// decoder reconstructs.  The decoded output was off by one for every
//// such run, which then failed the block CRC.
////
//// Fix: drop the extra raw byte; the closing count byte already
//// accounts for the 259th byte of the run.

import gleeunit/should
import packkit/bzip2

pub fn bug3_repeated_a_1k_test() -> Nil {
  let payload = byte_repeat(0x61, 1000)
  let assert Ok(encoded) = bzip2.encode(bytes: payload)
  bzip2.decode(bytes: encoded)
  |> should.equal(Ok(payload))
}

pub fn bug3_zeros_1k_test() -> Nil {
  let payload = byte_repeat(0x00, 1000)
  let assert Ok(encoded) = bzip2.encode(bytes: payload)
  bzip2.decode(bytes: encoded)
  |> should.equal(Ok(payload))
}

/// Triggered by every tarball — tar headers pad short fields with NUL.
/// Before the fix, `tar+bzip2` could never round-trip because the tar
/// padding produced long zero runs that broke RLE1.
pub fn bug3_long_zero_run_3000_test() -> Nil {
  let payload = byte_repeat(0x00, 3000)
  let assert Ok(encoded) = bzip2.encode(bytes: payload)
  bzip2.decode(bytes: encoded)
  |> should.equal(Ok(payload))
}

/// Boundary: 259 bytes is the exact length that fits one count byte.
pub fn bug3_run_at_259_boundary_test() -> Nil {
  let payload = byte_repeat(0x41, 259)
  let assert Ok(encoded) = bzip2.encode(bytes: payload)
  bzip2.decode(bytes: encoded)
  |> should.equal(Ok(payload))
}

/// Boundary: 260 bytes = one max-count run + one trailing byte.
pub fn bug3_run_at_260_boundary_test() -> Nil {
  let payload = byte_repeat(0x41, 260)
  let assert Ok(encoded) = bzip2.encode(bytes: payload)
  bzip2.decode(bytes: encoded)
  |> should.equal(Ok(payload))
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
