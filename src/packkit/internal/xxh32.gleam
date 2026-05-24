//// Pure-Gleam implementation of the xxHash32 algorithm.
////
//// Only the variant required by the LZ4 frame format is exposed:
//// `digest(bytes, seed)` returns the 32-bit hash as a non-negative
//// `Int`.  LZ4 frame headers are always shorter than 16 bytes
//// (FLG + BD + at most an 8-byte content size + an optional 4-byte
//// dictionary id = 14 bytes maximum), so this implementation
//// covers only the "short input" branch of xxHash32.  Adding
//// support for longer inputs would require the 16-byte block
//// loop; until a caller actually needs it, keeping the surface
//// small means there is less untested code to drift.
////
//// The arithmetic is split into 16-bit halves so partial products
//// stay within the 53-bit safe-integer range that the JavaScript
//// target requires.

import gleam/bit_array
import gleam/int

const mask32: Int = 0xFFFFFFFF

const prime1: Int = 0x9E3779B1

const prime2: Int = 0x85EBCA77

const prime3: Int = 0xC2B2AE3D

const prime4: Int = 0x27D4EB2F

const prime5: Int = 0x165667B1

/// Compute the xxHash32 of a short (< 16 byte) input.  Inputs of
/// 16 bytes or more are clamped to their leading 15 bytes — there
/// is no production caller that ever passes more than 14 bytes,
/// so clamping is preferable to crashing.  Callers that genuinely
/// need long-input support should extend this module with the
/// 16-byte block loop.
pub fn digest(bytes bytes: BitArray, seed seed: Int) -> Int {
  let total = bit_array.byte_size(bytes)
  let #(slice, slice_len) = case bit_array.slice(bytes, 0, 15) {
    Ok(prefix) if total >= 16 -> #(prefix, 15)
    _ -> #(bytes, total)
  }
  let initial = add32(seed, prime5)
  let with_length = add32(initial, slice_len)
  let after_tail = mix_tail(slice, with_length)
  avalanche(after_tail)
}

fn mix_tail(bytes: BitArray, h: Int) -> Int {
  case bytes {
    <<lane:size(32)-little, rest:bytes>> -> {
      let next = mul32(rotl32(add32(h, mul32(lane, prime3)), 17), prime4)
      mix_tail(rest, next)
    }
    <<byte, rest:bytes>> -> {
      let next = mul32(rotl32(add32(h, mul32(byte, prime5)), 11), prime1)
      mix_tail(rest, next)
    }
    _ -> h
  }
}

fn avalanche(state: Int) -> Int {
  let xored_high = int.bitwise_exclusive_or(state, shr32(state, 15))
  let multiplied_by_p2 = mul32(xored_high, prime2)
  let xored_mid =
    int.bitwise_exclusive_or(multiplied_by_p2, shr32(multiplied_by_p2, 13))
  let multiplied_by_p3 = mul32(xored_mid, prime3)
  int.bitwise_exclusive_or(multiplied_by_p3, shr32(multiplied_by_p3, 16))
}

fn add32(a: Int, b: Int) -> Int {
  int.bitwise_and(a + b, mask32)
}

fn shr32(value: Int, n: Int) -> Int {
  int.bitwise_shift_right(int.bitwise_and(value, mask32), n)
}

fn rotl32(value: Int, by_bits: Int) -> Int {
  let masked = int.bitwise_and(value, mask32)
  int.bitwise_and(
    int.bitwise_or(
      int.bitwise_shift_left(masked, by_bits),
      int.bitwise_shift_right(masked, 32 - by_bits),
    ),
    mask32,
  )
}

fn mul32(a: Int, b: Int) -> Int {
  // Split the second operand into low and high 16-bit halves so the
  // partial products fit inside the 53-bit safe-integer range that
  // the JavaScript target requires.
  let a_low = int.bitwise_and(a, 0xFFFF)
  let a_high = int.bitwise_shift_right(int.bitwise_and(a, mask32), 16)
  let b_low = int.bitwise_and(b, 0xFFFF)
  let b_high = int.bitwise_shift_right(int.bitwise_and(b, mask32), 16)
  let low_low = a_low * b_low
  let cross = int.bitwise_and(a_low * b_high + a_high * b_low, 0xFFFF)
  int.bitwise_and(low_low + int.bitwise_shift_left(cross, 16), mask32)
}
