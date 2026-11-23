//// Pure-Gleam implementation of the xxHash32 algorithm, used by the LZ4
//// frame format for the header, block and content checksums.
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

/// Computes the xxHash32 of `bytes` as a non-negative `Int`.
pub fn digest(bytes bytes: BitArray, seed seed: Int) -> Int {
  let total = bit_array.byte_size(bytes)
  let #(h, tail) = case total >= 16 {
    True -> {
      let lanes =
        stripes(
          bytes,
          add32(add32(seed, prime1), prime2),
          add32(seed, prime2),
          int.bitwise_and(seed, mask32),
          add32(seed, mask32 + 1 - prime1),
        )
      #(lanes.0, lanes.1)
    }
    False -> #(add32(seed, prime5), bytes)
  }
  avalanche(mix_tail(tail, add32(h, total)))
}

// Consumes 16-byte stripes into four accumulators, then merges them.
fn stripes(
  bytes: BitArray,
  v1: Int,
  v2: Int,
  v3: Int,
  v4: Int,
) -> #(Int, BitArray) {
  case bytes {
    <<
      a:size(32)-little,
      b:size(32)-little,
      c:size(32)-little,
      d:size(32)-little,
      rest:bytes,
    >> -> stripes(rest, round(v1, a), round(v2, b), round(v3, c), round(v4, d))
    _ -> {
      let merged =
        add32(
          add32(rotl32(v1, 1), rotl32(v2, 7)),
          add32(rotl32(v3, 12), rotl32(v4, 18)),
        )
      #(merged, bytes)
    }
  }
}

fn round(acc: Int, lane: Int) -> Int {
  mul32(rotl32(add32(acc, mul32(lane, prime2)), 13), prime1)
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
