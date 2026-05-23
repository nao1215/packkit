//// Regression tests for previously-known LZW round-trip bugs.
////
//// Each test pins the FIXED behavior so we notice immediately if a
//// future change re-introduces the symptom.

import gleam/bool
import gleeunit/should
import packkit/lzw

/// Encoding then decoding `[0, 1, …, 255]` used to inject an extra `0`
/// byte between positions 254 and 255 (round trip produced
/// `[0, 1, …, 254, 0, 255]`).  Root cause: the decoder's width-promote
/// check used `free_ent > max_code`, which fires one iteration too
/// late given the classical LZW insert-pair asymmetry — the encoder
/// pads to a 9-bit-byte-block boundary right after writing code 254,
/// but the decoder used to read those zero pad bits as a phantom
/// literal code 0.  Switching the decoder to `free_ent >= max_code`
/// promotes between codes 254 and 255 instead, matching where the
/// encoder pads.  See [packkit/lzw.promote_decoder_width].
pub fn bug4_lzw_byte_range_inserts_extra_zero_test() -> Nil {
  let payload = byte_range(0, 256, <<>>)
  let assert Ok(encoded) = lzw.encode(bytes: payload)
  lzw.decode(bytes: encoded)
  |> should.equal(Ok(payload))
}

/// Round-trip just past the 9→10 bit promote boundary (257 bytes:
/// `[0..255, 0]`).  Exercises the first POST-promote write of a code
/// at the new width.  This used to corrupt at the same boundary as
/// the 256-byte case above.
pub fn lzw_byte_range_plus_one_test() -> Nil {
  let payload = byte_range(0, 256, <<>>)
  let payload = <<payload:bits, 0>>
  let assert Ok(encoded) = lzw.encode(bytes: payload)
  lzw.decode(bytes: encoded)
  |> should.equal(Ok(payload))
}

/// Just below the promote boundary (255 bytes: `[0..254]`).  Ensures
/// the fix didn't pre-promote one iteration too eagerly when there's
/// no actual padding in the stream.
pub fn lzw_byte_range_minus_one_test() -> Nil {
  let payload = byte_range(0, 255, <<>>)
  let assert Ok(encoded) = lzw.encode(bytes: payload)
  lzw.decode(bytes: encoded)
  |> should.equal(Ok(payload))
}

fn byte_range(from: Int, until: Int, acc: BitArray) -> BitArray {
  use <- bool.guard(when: from >= until, return: acc)
  byte_range(from + 1, until, <<acc:bits, from>>)
}
