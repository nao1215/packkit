//// Adler-32 and CRC-32 checksums used by zlib (RFC 1950) and gzip
//// (RFC 1952).
////
//// The implementations are pure Gleam and behave identically on the
//// Erlang and JavaScript targets.

import gleam/bit_array
import gleam/int

const adler32_base: Int = 65_521

const adler32_nmax: Int = 5552

const crc32_init: Int = 4_294_967_295

const u32_mask: Int = 4_294_967_295

/// Compute the Adler-32 checksum of `data`, returning the canonical
/// 32-bit value `(s2 << 16) | s1`.
pub fn adler32(data data: BitArray) -> Int {
  let length = bit_array.byte_size(data)
  adler32_loop(data, length, 1, 0)
}

/// Continue an Adler-32 computation from a previous checksum value.
pub fn adler32_continue(previous previous: Int, data data: BitArray) -> Int {
  let s1 = int.bitwise_and(previous, 65_535)
  let s2 = int.bitwise_and(int.bitwise_shift_right(previous, 16), 65_535)
  let length = bit_array.byte_size(data)
  adler32_loop(data, length, s1, s2)
}

fn adler32_loop(data: BitArray, remaining: Int, s1: Int, s2: Int) -> Int {
  case remaining {
    0 -> combine_adler(s1, s2)
    _ -> {
      let k = case remaining < adler32_nmax {
        True -> remaining
        False -> adler32_nmax
      }
      let #(rest, new_s1, new_s2) = adler32_chunk(data, k, s1, s2)
      let new_s1 = mod(new_s1, adler32_base)
      let new_s2 = mod(new_s2, adler32_base)
      adler32_loop(rest, remaining - k, new_s1, new_s2)
    }
  }
}

fn adler32_chunk(
  data: BitArray,
  remaining: Int,
  s1: Int,
  s2: Int,
) -> #(BitArray, Int, Int) {
  case remaining, data {
    0, _ -> #(data, s1, s2)
    _, <<b, rest:bytes>> -> {
      let s1 = s1 + b
      let s2 = s2 + s1
      adler32_chunk(rest, remaining - 1, s1, s2)
    }
    _, _ -> #(data, s1, s2)
  }
}

fn combine_adler(s1: Int, s2: Int) -> Int {
  int.bitwise_or(int.bitwise_shift_left(s2, 16), s1)
}

/// Compute the CRC-32 checksum of `data` using the IEEE 802.3 reflected
/// polynomial `0xEDB88320` and the same final XOR as zlib's `crc32`.
pub fn crc32(data data: BitArray) -> Int {
  let crc = crc32_loop(data, crc32_init)
  int.bitwise_and(int.bitwise_exclusive_or(crc, crc32_init), u32_mask)
}

/// Continue a CRC-32 computation from a previous checksum value.
pub fn crc32_continue(previous previous: Int, data data: BitArray) -> Int {
  let crc =
    int.bitwise_exclusive_or(int.bitwise_and(previous, u32_mask), crc32_init)
  let crc = crc32_loop(data, crc)
  int.bitwise_and(int.bitwise_exclusive_or(crc, crc32_init), u32_mask)
}

fn crc32_loop(data: BitArray, crc: Int) -> Int {
  case data {
    <<b, rest:bytes>> -> {
      let crc = int.bitwise_exclusive_or(crc, b)
      let crc = step4(crc)
      let crc = step4(crc)
      crc32_loop(rest, crc)
    }
    _ -> crc
  }
}

fn step4(crc: Int) -> Int {
  let low = int.bitwise_and(crc, 15)
  let shifted = int.bitwise_shift_right(crc, 4)
  int.bitwise_exclusive_or(crc32_nibble(low), shifted)
}

fn crc32_nibble(index: Int) -> Int {
  case index {
    0 -> 0x00000000
    1 -> 0x1DB71064
    2 -> 0x3B6E20C8
    3 -> 0x26D930AC
    4 -> 0x76DC4190
    5 -> 0x6B6B51F4
    6 -> 0x4DB26158
    7 -> 0x5005713C
    8 -> 0xEDB88320
    9 -> 0xF00F9344
    10 -> 0xD6D6A3E8
    11 -> 0xCB61B38C
    12 -> 0x9B64C2B0
    13 -> 0x86D3D2D4
    14 -> 0xA00AE278
    _ -> 0xBDBDF21C
  }
}

fn mod(value: Int, divisor: Int) -> Int {
  value - { value / divisor } * divisor
}
