//// Adler-32 and CRC-32 checksums used by zlib (RFC 1950) and gzip
//// (RFC 1952).
////
//// The implementations are pure Gleam and behave identically on the
//// Erlang and JavaScript targets.

import gleam/bit_array
import gleam/int
import gleam/list

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

/// Compute the CRC-32C (Castagnoli) checksum of `data` using the
/// reflected polynomial `0x82F63B78`.  CRC-32C underlies the masked
/// checksums in Snappy's frame format.
pub fn crc32c(data data: BitArray) -> Int {
  let crc = crc32c_loop(data, crc32_init)
  int.bitwise_and(int.bitwise_exclusive_or(crc, crc32_init), u32_mask)
}

/// Compute the bzip2 CRC-32 of `data`.
///
/// bzip2 reuses the IEEE 802.3 polynomial `0x04C11DB7` but processes
/// each byte MSB-first (without reflection) and XORs the final value
/// with `0xFFFFFFFF`, matching the per-block and stream CRC fields
/// that appear in `.bz2` files.
pub fn bzip2_crc32(data data: BitArray) -> Int {
  let crc = bzip2_crc32_loop(data, crc32_init)
  int.bitwise_and(int.bitwise_exclusive_or(crc, crc32_init), u32_mask)
}

fn bzip2_crc32_loop(data: BitArray, crc: Int) -> Int {
  case data {
    <<b, rest:bytes>> -> {
      let crc =
        int.bitwise_exclusive_or(crc, int.bitwise_shift_left(b, 24))
        |> int.bitwise_and(u32_mask)
      let crc = bzip2_step_byte(crc)
      bzip2_crc32_loop(rest, crc)
    }
    _ -> crc
  }
}

fn bzip2_step_byte(crc: Int) -> Int {
  bzip2_step_bit(crc)
  |> bzip2_step_bit
  |> bzip2_step_bit
  |> bzip2_step_bit
  |> bzip2_step_bit
  |> bzip2_step_bit
  |> bzip2_step_bit
  |> bzip2_step_bit
}

fn bzip2_step_bit(crc: Int) -> Int {
  let shifted = int.bitwise_and(int.bitwise_shift_left(crc, 1), u32_mask)
  case int.bitwise_and(crc, 0x80000000) {
    0 -> shifted
    _ -> int.bitwise_exclusive_or(shifted, 0x04C11DB7)
  }
}

/// Compute the CRC-64 (ECMA-182, reflected) checksum of `data` used
/// by the xz block-check field (`check_type = 4`, see RFC `xz-format`
/// §2.1.1.2).  Polynomial `0x42F0E1EBA9EA3693` reflected to
/// `0xC96C5795D7870F42`, init / final-xor `0xFFFFFFFFFFFFFFFF`.
///
/// The result is returned as a `#(low_u32, high_u32)` pair instead of
/// a single 64-bit Int so the implementation stays exact on the
/// JavaScript target, whose `Number` cannot safely represent the full
/// 64-bit space and whose bitwise operators are 32-bit anyway.
pub fn crc64_xz(data data: BitArray) -> #(Int, Int) {
  let #(low, high) = crc64_loop(data, u32_mask, u32_mask)
  #(
    int.bitwise_and(int.bitwise_exclusive_or(low, u32_mask), u32_mask),
    int.bitwise_and(int.bitwise_exclusive_or(high, u32_mask), u32_mask),
  )
}

fn crc64_loop(data: BitArray, low: Int, high: Int) -> #(Int, Int) {
  case data {
    <<b, rest:bytes>> -> {
      let low = int.bitwise_exclusive_or(low, b)
      let #(low, high) = crc64_step4(low, high)
      let #(low, high) = crc64_step4(low, high)
      crc64_loop(rest, low, high)
    }
    _ -> #(low, high)
  }
}

fn crc64_step4(low: Int, high: Int) -> #(Int, Int) {
  let nibble = int.bitwise_and(low, 15)
  // Shift the 64-bit register right by 4: the bottom 4 bits of high
  // become the top 4 bits of low, and high's own top 4 bits go to 0.
  let new_low =
    int.bitwise_or(
      int.bitwise_shift_right(low, 4),
      int.bitwise_and(int.bitwise_shift_left(high, 28), u32_mask),
    )
  let new_high = int.bitwise_shift_right(high, 4)
  #(
    int.bitwise_exclusive_or(new_low, crc64_nibble_low(nibble)),
    int.bitwise_exclusive_or(new_high, crc64_nibble_high(nibble)),
  )
}

fn crc64_nibble_low(index: Int) -> Int {
  case index {
    0 -> 0x00000000
    1 -> 0x51336649
    2 -> 0xA266CC92
    3 -> 0xF355AADB
    4 -> 0xEBC387A1
    5 -> 0xBAF0E1E8
    6 -> 0x49A54B33
    7 -> 0x18962D7A
    8 -> 0xD7870F42
    9 -> 0x86B4690B
    10 -> 0x75E1C3D0
    11 -> 0x24D2A599
    12 -> 0x3C4488E3
    13 -> 0x6D77EEAA
    14 -> 0x9E224471
    _ -> 0xCF112238
  }
}

fn crc64_nibble_high(index: Int) -> Int {
  case index {
    0 -> 0x00000000
    1 -> 0x7D9BA138
    2 -> 0xFB374270
    3 -> 0x86ACE348
    4 -> 0x64B62BCA
    5 -> 0x192D8AF2
    6 -> 0x9F8169BA
    7 -> 0xE21AC882
    8 -> 0xC96C5795
    9 -> 0xB4F7F6AD
    10 -> 0x325B15E5
    11 -> 0x4FC0B4DD
    12 -> 0xADDA7C5F
    13 -> 0xD041DD67
    14 -> 0x56ED3E2F
    _ -> 0x2B769F17
  }
}

/// Mask a CRC-32C value as Snappy's framing layer requires.
///
/// The masking is `((crc >> 15) | (crc << 17)) + 0xa282ead8` taken
/// modulo `2^32`.
pub fn snappy_mask(crc crc: Int) -> Int {
  let high = int.bitwise_shift_right(crc, 15)
  let low = int.bitwise_and(int.bitwise_shift_left(crc, 17), u32_mask)
  let rotated = int.bitwise_or(high, low)
  int.bitwise_and(rotated + 0xA282EAD8, u32_mask)
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

fn crc32c_loop(data: BitArray, crc: Int) -> Int {
  case data {
    <<b, rest:bytes>> -> {
      let crc = int.bitwise_exclusive_or(crc, b)
      let crc = step4_c(crc)
      let crc = step4_c(crc)
      crc32c_loop(rest, crc)
    }
    _ -> crc
  }
}

fn step4_c(crc: Int) -> Int {
  let low = int.bitwise_and(crc, 15)
  let shifted = int.bitwise_shift_right(crc, 4)
  int.bitwise_exclusive_or(crc32c_nibble(low), shifted)
}

fn crc32c_nibble(index: Int) -> Int {
  case index {
    0 -> 0x00000000
    1 -> 0x105EC76F
    2 -> 0x20BD8EDE
    3 -> 0x30E349B1
    4 -> 0x417B1DBC
    5 -> 0x5125DAD3
    6 -> 0x61C69362
    7 -> 0x7198540D
    8 -> 0x82F63B78
    9 -> 0x92A8FC17
    10 -> 0xA24BB5A6
    11 -> 0xB21572C9
    12 -> 0xC38D26C4
    13 -> 0xD3D3E1AB
    14 -> 0xE330A81A
    _ -> 0xF36E6F75
  }
}

fn mod(value: Int, divisor: Int) -> Int {
  value - { value / divisor } * divisor
}

// -- SHA-256 (FIPS 180-4) -----------------------------------------------

/// Compute the SHA-256 digest of `data` and return the 32-byte digest
/// as a `BitArray`.  Used by the xz block-check field (`check_type =
/// 10`).
pub fn sha256(data data: BitArray) -> BitArray {
  let padded = sha256_pad(data)
  let #(h0, h1, h2, h3, h4, h5, h6, h7) =
    sha256_process_blocks(
      padded,
      0x6A09E667,
      0xBB67AE85,
      0x3C6EF372,
      0xA54FF53A,
      0x510E527F,
      0x9B05688C,
      0x1F83D9AB,
      0x5BE0CD19,
    )
  <<
    h0:size(32),
    h1:size(32),
    h2:size(32),
    h3:size(32),
    h4:size(32),
    h5:size(32),
    h6:size(32),
    h7:size(32),
  >>
}

/// Pad `data` to a multiple of 64 bytes following FIPS 180-4 §5.1.1:
/// append `0x80`, then enough `0x00` to leave 8 bytes for the
/// 64-bit big-endian bit-length.
fn sha256_pad(data: BitArray) -> BitArray {
  let len = bit_array.byte_size(data)
  let bit_len = len * 8
  // After appending 0x80, we need (len + 1 + zeros + 8) ≡ 0 (mod 64).
  let mod_len = mod(len + 9, 64)
  let zeros = case mod_len {
    0 -> 0
    n -> 64 - n
  }
  let padding = pad_zeros(zeros, <<>>)
  bit_array.concat([data, <<0x80>>, padding, <<bit_len:size(64)-big>>])
}

fn pad_zeros(count: Int, acc: BitArray) -> BitArray {
  case count {
    0 -> acc
    _ -> pad_zeros(count - 1, bit_array.concat([acc, <<0>>]))
  }
}

fn sha256_process_blocks(
  data: BitArray,
  h0: Int,
  h1: Int,
  h2: Int,
  h3: Int,
  h4: Int,
  h5: Int,
  h6: Int,
  h7: Int,
) -> #(Int, Int, Int, Int, Int, Int, Int, Int) {
  case data {
    <<>> -> #(h0, h1, h2, h3, h4, h5, h6, h7)
    <<
      w0:size(32)-big,
      w1:size(32)-big,
      w2:size(32)-big,
      w3:size(32)-big,
      w4:size(32)-big,
      w5:size(32)-big,
      w6:size(32)-big,
      w7:size(32)-big,
      w8:size(32)-big,
      w9:size(32)-big,
      w10:size(32)-big,
      w11:size(32)-big,
      w12:size(32)-big,
      w13:size(32)-big,
      w14:size(32)-big,
      w15:size(32)-big,
      rest:bytes,
    >> -> {
      let initial = [
        w15,
        w14,
        w13,
        w12,
        w11,
        w10,
        w9,
        w8,
        w7,
        w6,
        w5,
        w4,
        w3,
        w2,
        w1,
        w0,
      ]
      let schedule = expand_schedule(initial, 16)
      let #(a, b, c, d, e, f, g, h) =
        sha256_compress(
          list.reverse(schedule),
          0,
          h0,
          h1,
          h2,
          h3,
          h4,
          h5,
          h6,
          h7,
        )
      sha256_process_blocks(
        rest,
        u32_add(h0, a),
        u32_add(h1, b),
        u32_add(h2, c),
        u32_add(h3, d),
        u32_add(h4, e),
        u32_add(h5, f),
        u32_add(h6, g),
        u32_add(h7, h),
      )
    }
    _ -> #(h0, h1, h2, h3, h4, h5, h6, h7)
  }
}

/// Build W[0..63] in reverse order (newest at head) so the head of the
/// list is `W[count - 1]`.  When `count` reaches 64 we have the full
/// schedule and the caller reverses it.
fn expand_schedule(reversed: List(Int), count: Int) -> List(Int) {
  case count {
    64 -> reversed
    _ -> {
      let w_m2 = nth_from_head(reversed, 1)
      let w_m7 = nth_from_head(reversed, 6)
      let w_m15 = nth_from_head(reversed, 14)
      let w_m16 = nth_from_head(reversed, 15)
      let s0 = sha256_small_sigma0(w_m15)
      let s1 = sha256_small_sigma1(w_m2)
      let next = u32_add(u32_add(u32_add(w_m16, s0), w_m7), s1)
      expand_schedule([next, ..reversed], count + 1)
    }
  }
}

fn nth_from_head(list_value: List(Int), index: Int) -> Int {
  case list_value, index {
    [head, ..], 0 -> head
    [_, ..rest], n -> nth_from_head(rest, n - 1)
    [], _ -> 0
  }
}

fn sha256_compress(
  schedule: List(Int),
  round: Int,
  a: Int,
  b: Int,
  c: Int,
  d: Int,
  e: Int,
  f: Int,
  g: Int,
  h: Int,
) -> #(Int, Int, Int, Int, Int, Int, Int, Int) {
  case schedule {
    [] -> #(a, b, c, d, e, f, g, h)
    [w, ..rest] -> {
      let s1 = sha256_big_sigma1(e)
      let ch =
        int.bitwise_exclusive_or(
          int.bitwise_and(e, f),
          int.bitwise_and(int.bitwise_exclusive_or(e, u32_mask), g),
        )
      let temp1 =
        u32_add(u32_add(u32_add(u32_add(h, s1), ch), sha256_k(round)), w)
      let s0 = sha256_big_sigma0(a)
      let maj =
        int.bitwise_exclusive_or(
          int.bitwise_exclusive_or(int.bitwise_and(a, b), int.bitwise_and(a, c)),
          int.bitwise_and(b, c),
        )
      let temp2 = u32_add(s0, maj)
      sha256_compress(
        rest,
        round + 1,
        u32_add(temp1, temp2),
        a,
        b,
        c,
        u32_add(d, temp1),
        e,
        f,
        g,
      )
    }
  }
}

fn u32_add(x: Int, y: Int) -> Int {
  int.bitwise_and(x + y, u32_mask)
}

fn u32_rotr(x: Int, n: Int) -> Int {
  let right = int.bitwise_shift_right(x, n)
  let left = int.bitwise_and(int.bitwise_shift_left(x, 32 - n), u32_mask)
  int.bitwise_or(right, left)
}

fn sha256_small_sigma0(x: Int) -> Int {
  int.bitwise_exclusive_or(
    int.bitwise_exclusive_or(u32_rotr(x, 7), u32_rotr(x, 18)),
    int.bitwise_shift_right(x, 3),
  )
}

fn sha256_small_sigma1(x: Int) -> Int {
  int.bitwise_exclusive_or(
    int.bitwise_exclusive_or(u32_rotr(x, 17), u32_rotr(x, 19)),
    int.bitwise_shift_right(x, 10),
  )
}

fn sha256_big_sigma0(x: Int) -> Int {
  int.bitwise_exclusive_or(
    int.bitwise_exclusive_or(u32_rotr(x, 2), u32_rotr(x, 13)),
    u32_rotr(x, 22),
  )
}

fn sha256_big_sigma1(x: Int) -> Int {
  int.bitwise_exclusive_or(
    int.bitwise_exclusive_or(u32_rotr(x, 6), u32_rotr(x, 11)),
    u32_rotr(x, 25),
  )
}

fn sha256_k(round: Int) -> Int {
  case round {
    0 -> 0x428A2F98
    1 -> 0x71374491
    2 -> 0xB5C0FBCF
    3 -> 0xE9B5DBA5
    4 -> 0x3956C25B
    5 -> 0x59F111F1
    6 -> 0x923F82A4
    7 -> 0xAB1C5ED5
    8 -> 0xD807AA98
    9 -> 0x12835B01
    10 -> 0x243185BE
    11 -> 0x550C7DC3
    12 -> 0x72BE5D74
    13 -> 0x80DEB1FE
    14 -> 0x9BDC06A7
    15 -> 0xC19BF174
    16 -> 0xE49B69C1
    17 -> 0xEFBE4786
    18 -> 0x0FC19DC6
    19 -> 0x240CA1CC
    20 -> 0x2DE92C6F
    21 -> 0x4A7484AA
    22 -> 0x5CB0A9DC
    23 -> 0x76F988DA
    24 -> 0x983E5152
    25 -> 0xA831C66D
    26 -> 0xB00327C8
    27 -> 0xBF597FC7
    28 -> 0xC6E00BF3
    29 -> 0xD5A79147
    30 -> 0x06CA6351
    31 -> 0x14292967
    32 -> 0x27B70A85
    33 -> 0x2E1B2138
    34 -> 0x4D2C6DFC
    35 -> 0x53380D13
    36 -> 0x650A7354
    37 -> 0x766A0ABB
    38 -> 0x81C2C92E
    39 -> 0x92722C85
    40 -> 0xA2BFE8A1
    41 -> 0xA81A664B
    42 -> 0xC24B8B70
    43 -> 0xC76C51A3
    44 -> 0xD192E819
    45 -> 0xD6990624
    46 -> 0xF40E3585
    47 -> 0x106AA070
    48 -> 0x19A4C116
    49 -> 0x1E376C08
    50 -> 0x2748774C
    51 -> 0x34B0BCB5
    52 -> 0x391C0CB3
    53 -> 0x4ED8AA4A
    54 -> 0x5B9CCA4F
    55 -> 0x682E6FF3
    56 -> 0x748F82EE
    57 -> 0x78A5636F
    58 -> 0x84C87814
    59 -> 0x8CC70208
    60 -> 0x90BEFFFA
    61 -> 0xA4506CEB
    62 -> 0xBEF9A3F7
    _ -> 0xC67178F2
  }
}
