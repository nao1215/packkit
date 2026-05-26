//// AES-128 / AES-192 / AES-256 block cipher — encrypt only.
////
//// This module is the cryptographic primitive ZIP AE-x decryption is
//// built on.  The WinZip AES extension uses AES in CTR mode, which
//// only needs the forward (encrypt) transform on a block of all-zero
//// or counter bytes — the ciphertext is then XOR'd into the plaintext
//// (decrypt direction is the same operation).  We intentionally do
//// NOT implement the inverse (decrypt) transform: keeping the
//// surface small reduces audit area and avoids the slower
//// inverse-S-box / inverse-MixColumns paths.
////
//// The implementation follows FIPS 197 §5.1 (Cipher) and §5.2
//// (Key Expansion).  Pure Gleam, no FFI: cross-target by construction
//// (Erlang + JavaScript), at the cost of being noticeably slower than
//// a native-extension AES.  Acceptable for the small (sub-MB)
//// per-entry payloads that ZIP AE-x typically wraps.

import gleam/bit_array
import gleam/int
import gleam/list

/// Opaque expanded-key value.  Hold onto one of these between calls
/// to `encrypt_block` (e.g. across CTR counter iterations) so the key
/// schedule is computed once rather than per block.
pub opaque type ExpandedKey {
  ExpandedKey(round_keys: List(Int), rounds: Int)
}

/// Expand a raw AES key (16 / 24 / 32 bytes) into per-round subkeys.
/// `rounds` is 10 / 12 / 14 respectively; the round-key list contains
/// `4 * (rounds + 1)` 32-bit big-endian words.  Any other key length
/// is rejected — the caller should derive the right key length via
/// PBKDF2 before getting here.
pub fn expand_key(key: BitArray) -> Result(ExpandedKey, Nil) {
  let key_words = bit_array_to_u32_words(key, [])
  let nk = list.length(key_words)
  case nk {
    4 -> Ok(do_expand(key_words, 4, 10))
    6 -> Ok(do_expand(key_words, 6, 12))
    8 -> Ok(do_expand(key_words, 8, 14))
    _ -> Error(Nil)
  }
}

fn do_expand(key_words: List(Int), nk: Int, rounds: Int) -> ExpandedKey {
  let total_words = 4 * { rounds + 1 }
  let reversed_initial = list.reverse(key_words)
  let reversed_all = expand_loop(reversed_initial, nk, nk, total_words)
  let round_keys = list.reverse(reversed_all)
  ExpandedKey(round_keys: round_keys, rounds: rounds)
}

fn expand_loop(
  reversed: List(Int),
  index: Int,
  nk: Int,
  total: Int,
) -> List(Int) {
  case index >= total {
    True -> reversed
    False -> {
      let assert [previous, ..] = reversed
      let assert Ok(word_nk_ago) = list.first(list.drop(reversed, nk - 1))
      let transformed = case index % nk {
        0 -> {
          // RotWord → SubWord → XOR Rcon
          let rotated = rotate_word(previous)
          let subbed = sub_word(rotated)
          let rcon = rcon_value(index / nk)
          int.bitwise_exclusive_or(subbed, rcon)
        }
        4 if nk > 6 -> sub_word(previous)
        _ -> previous
      }
      let next = int.bitwise_exclusive_or(word_nk_ago, transformed)
      expand_loop([next, ..reversed], index + 1, nk, total)
    }
  }
}

fn rotate_word(word: Int) -> Int {
  let high = int.bitwise_and(int.bitwise_shift_left(word, 8), u32_mask)
  let low = int.bitwise_shift_right(word, 24)
  int.bitwise_or(high, low)
}

fn sub_word(word: Int) -> Int {
  let b0 = sbox(int.bitwise_and(int.bitwise_shift_right(word, 24), 0xFF))
  let b1 = sbox(int.bitwise_and(int.bitwise_shift_right(word, 16), 0xFF))
  let b2 = sbox(int.bitwise_and(int.bitwise_shift_right(word, 8), 0xFF))
  let b3 = sbox(int.bitwise_and(word, 0xFF))
  int.bitwise_or(
    int.bitwise_or(
      int.bitwise_or(
        int.bitwise_shift_left(b0, 24),
        int.bitwise_shift_left(b1, 16),
      ),
      int.bitwise_shift_left(b2, 8),
    ),
    b3,
  )
}

fn rcon_value(round: Int) -> Int {
  let rc = rcon_byte(round)
  int.bitwise_shift_left(rc, 24)
}

fn rcon_byte(round: Int) -> Int {
  case round {
    1 -> 0x01
    2 -> 0x02
    3 -> 0x04
    4 -> 0x08
    5 -> 0x10
    6 -> 0x20
    7 -> 0x40
    8 -> 0x80
    9 -> 0x1B
    10 -> 0x36
    _ -> 0x00
  }
}

/// Encrypt one 16-byte block under the expanded key.  Returns the
/// 16-byte ciphertext block.  Input shorter or longer than 16 bytes
/// is an error — `Error(Nil)` rather than a panic so callers in tight
/// loops can branch cleanly.
pub fn encrypt_block(key: ExpandedKey, block: BitArray) -> Result(BitArray, Nil) {
  case bit_array.byte_size(block) {
    16 -> {
      let state = bit_array_to_u32_words(block, [])
      let state_xored = add_round_key(state, key.round_keys, 0)
      let final_state =
        encrypt_rounds(state_xored, key.round_keys, 1, key.rounds)
      Ok(u32_words_to_bit_array(final_state, <<>>))
    }
    _ -> Error(Nil)
  }
}

fn encrypt_rounds(
  state: List(Int),
  round_keys: List(Int),
  round: Int,
  total: Int,
) -> List(Int) {
  case round {
    n if n == total -> {
      // Final round: SubBytes → ShiftRows → AddRoundKey (no MixColumns).
      let after_sub = sub_bytes(state)
      let after_shift = shift_rows(after_sub)
      add_round_key(after_shift, round_keys, total)
    }
    _ -> {
      let after_sub = sub_bytes(state)
      let after_shift = shift_rows(after_sub)
      let after_mix = mix_columns(after_shift)
      let after_key = add_round_key(after_mix, round_keys, round)
      encrypt_rounds(after_key, round_keys, round + 1, total)
    }
  }
}

fn add_round_key(
  state: List(Int),
  round_keys: List(Int),
  round: Int,
) -> List(Int) {
  let key_slice = list.take(list.drop(round_keys, round * 4), 4)
  xor_word_lists(state, key_slice, [])
}

fn xor_word_lists(a: List(Int), b: List(Int), acc: List(Int)) -> List(Int) {
  case a, b {
    [], _ | _, [] -> list.reverse(acc)
    [x, ..rest_a], [y, ..rest_b] ->
      xor_word_lists(rest_a, rest_b, [int.bitwise_exclusive_or(x, y), ..acc])
  }
}

fn sub_bytes(state: List(Int)) -> List(Int) {
  list.map(state, sub_word)
}

fn shift_rows(state: List(Int)) -> List(Int) {
  // AES state is column-major: state[col][row] with col, row ∈ [0,3].
  // Our `state` list holds 4 columns, each as one 32-bit word stored
  // big-endian (highest byte = row 0).  ShiftRows rotates row `r` left
  // by `r` bytes, which is the standard "permute the 16 bytes" step.
  let bytes_in = words_to_bytes(state)
  let assert [
    b0,
    b1,
    b2,
    b3,
    b4,
    b5,
    b6,
    b7,
    b8,
    b9,
    b10,
    b11,
    b12,
    b13,
    b14,
    b15,
  ] = bytes_in
  // Row 0 (b0, b4, b8, b12): no shift.
  // Row 1 (b1, b5, b9, b13): left shift by 1 → (b5, b9, b13, b1).
  // Row 2 (b2, b6, b10, b14): left shift by 2 → (b10, b14, b2, b6).
  // Row 3 (b3, b7, b11, b15): left shift by 3 → (b15, b3, b7, b11).
  bytes_to_words([
    b0, b5, b10, b15, b4, b9, b14, b3, b8, b13, b2, b7, b12, b1, b6, b11,
  ])
}

fn mix_columns(state: List(Int)) -> List(Int) {
  list.map(state, mix_one_column)
}

fn mix_one_column(word: Int) -> Int {
  let s0 = int.bitwise_and(int.bitwise_shift_right(word, 24), 0xFF)
  let s1 = int.bitwise_and(int.bitwise_shift_right(word, 16), 0xFF)
  let s2 = int.bitwise_and(int.bitwise_shift_right(word, 8), 0xFF)
  let s3 = int.bitwise_and(word, 0xFF)
  let r0 = mix_xor4(gmul2(s0), gmul3(s1), s2, s3)
  let r1 = mix_xor4(s0, gmul2(s1), gmul3(s2), s3)
  let r2 = mix_xor4(s0, s1, gmul2(s2), gmul3(s3))
  let r3 = mix_xor4(gmul3(s0), s1, s2, gmul2(s3))
  int.bitwise_or(
    int.bitwise_or(
      int.bitwise_or(
        int.bitwise_shift_left(r0, 24),
        int.bitwise_shift_left(r1, 16),
      ),
      int.bitwise_shift_left(r2, 8),
    ),
    r3,
  )
}

fn mix_xor4(a: Int, b: Int, c: Int, d: Int) -> Int {
  int.bitwise_exclusive_or(
    int.bitwise_exclusive_or(a, b),
    int.bitwise_exclusive_or(c, d),
  )
}

// GF(2^8) multiplication by 2 (xtime): shift left, conditionally XOR
// the AES reduction polynomial 0x1B when the high bit was set.
fn gmul2(value: Int) -> Int {
  let shifted = int.bitwise_and(int.bitwise_shift_left(value, 1), 0xFF)
  case int.bitwise_and(value, 0x80) {
    0 -> shifted
    _ -> int.bitwise_exclusive_or(shifted, 0x1B)
  }
}

fn gmul3(value: Int) -> Int {
  int.bitwise_exclusive_or(gmul2(value), value)
}

// -- byte / word helpers --------------------------------------------

const u32_mask: Int = 0xFFFFFFFF

fn bit_array_to_u32_words(bytes: BitArray, acc: List(Int)) -> List(Int) {
  case bytes {
    <<word:size(32)-big, rest:bytes>> ->
      bit_array_to_u32_words(rest, [word, ..acc])
    _ -> list.reverse(acc)
  }
}

fn u32_words_to_bit_array(words: List(Int), acc: BitArray) -> BitArray {
  case words {
    [] -> acc
    [w, ..rest] ->
      u32_words_to_bit_array(rest, bit_array.concat([acc, <<w:size(32)-big>>]))
  }
}

fn words_to_bytes(words: List(Int)) -> List(Int) {
  words_to_bytes_loop(words, [])
}

fn words_to_bytes_loop(words: List(Int), acc: List(Int)) -> List(Int) {
  case words {
    [] -> list.reverse(acc)
    [w, ..rest] -> {
      let b0 = int.bitwise_and(int.bitwise_shift_right(w, 24), 0xFF)
      let b1 = int.bitwise_and(int.bitwise_shift_right(w, 16), 0xFF)
      let b2 = int.bitwise_and(int.bitwise_shift_right(w, 8), 0xFF)
      let b3 = int.bitwise_and(w, 0xFF)
      words_to_bytes_loop(rest, [b3, b2, b1, b0, ..acc])
    }
  }
}

fn bytes_to_words(bytes: List(Int)) -> List(Int) {
  bytes_to_words_loop(bytes, [])
}

fn bytes_to_words_loop(bytes: List(Int), acc: List(Int)) -> List(Int) {
  case bytes {
    [b0, b1, b2, b3, ..rest] -> {
      let word =
        int.bitwise_or(
          int.bitwise_or(
            int.bitwise_or(
              int.bitwise_shift_left(b0, 24),
              int.bitwise_shift_left(b1, 16),
            ),
            int.bitwise_shift_left(b2, 8),
          ),
          b3,
        )
      bytes_to_words_loop(rest, [word, ..acc])
    }
    _ -> list.reverse(acc)
  }
}

// -- AES S-box ------------------------------------------------------

fn sbox(byte: Int) -> Int {
  case byte {
    0x00 -> 0x63
    0x01 -> 0x7C
    0x02 -> 0x77
    0x03 -> 0x7B
    0x04 -> 0xF2
    0x05 -> 0x6B
    0x06 -> 0x6F
    0x07 -> 0xC5
    0x08 -> 0x30
    0x09 -> 0x01
    0x0A -> 0x67
    0x0B -> 0x2B
    0x0C -> 0xFE
    0x0D -> 0xD7
    0x0E -> 0xAB
    0x0F -> 0x76
    0x10 -> 0xCA
    0x11 -> 0x82
    0x12 -> 0xC9
    0x13 -> 0x7D
    0x14 -> 0xFA
    0x15 -> 0x59
    0x16 -> 0x47
    0x17 -> 0xF0
    0x18 -> 0xAD
    0x19 -> 0xD4
    0x1A -> 0xA2
    0x1B -> 0xAF
    0x1C -> 0x9C
    0x1D -> 0xA4
    0x1E -> 0x72
    0x1F -> 0xC0
    0x20 -> 0xB7
    0x21 -> 0xFD
    0x22 -> 0x93
    0x23 -> 0x26
    0x24 -> 0x36
    0x25 -> 0x3F
    0x26 -> 0xF7
    0x27 -> 0xCC
    0x28 -> 0x34
    0x29 -> 0xA5
    0x2A -> 0xE5
    0x2B -> 0xF1
    0x2C -> 0x71
    0x2D -> 0xD8
    0x2E -> 0x31
    0x2F -> 0x15
    0x30 -> 0x04
    0x31 -> 0xC7
    0x32 -> 0x23
    0x33 -> 0xC3
    0x34 -> 0x18
    0x35 -> 0x96
    0x36 -> 0x05
    0x37 -> 0x9A
    0x38 -> 0x07
    0x39 -> 0x12
    0x3A -> 0x80
    0x3B -> 0xE2
    0x3C -> 0xEB
    0x3D -> 0x27
    0x3E -> 0xB2
    0x3F -> 0x75
    0x40 -> 0x09
    0x41 -> 0x83
    0x42 -> 0x2C
    0x43 -> 0x1A
    0x44 -> 0x1B
    0x45 -> 0x6E
    0x46 -> 0x5A
    0x47 -> 0xA0
    0x48 -> 0x52
    0x49 -> 0x3B
    0x4A -> 0xD6
    0x4B -> 0xB3
    0x4C -> 0x29
    0x4D -> 0xE3
    0x4E -> 0x2F
    0x4F -> 0x84
    0x50 -> 0x53
    0x51 -> 0xD1
    0x52 -> 0x00
    0x53 -> 0xED
    0x54 -> 0x20
    0x55 -> 0xFC
    0x56 -> 0xB1
    0x57 -> 0x5B
    0x58 -> 0x6A
    0x59 -> 0xCB
    0x5A -> 0xBE
    0x5B -> 0x39
    0x5C -> 0x4A
    0x5D -> 0x4C
    0x5E -> 0x58
    0x5F -> 0xCF
    0x60 -> 0xD0
    0x61 -> 0xEF
    0x62 -> 0xAA
    0x63 -> 0xFB
    0x64 -> 0x43
    0x65 -> 0x4D
    0x66 -> 0x33
    0x67 -> 0x85
    0x68 -> 0x45
    0x69 -> 0xF9
    0x6A -> 0x02
    0x6B -> 0x7F
    0x6C -> 0x50
    0x6D -> 0x3C
    0x6E -> 0x9F
    0x6F -> 0xA8
    0x70 -> 0x51
    0x71 -> 0xA3
    0x72 -> 0x40
    0x73 -> 0x8F
    0x74 -> 0x92
    0x75 -> 0x9D
    0x76 -> 0x38
    0x77 -> 0xF5
    0x78 -> 0xBC
    0x79 -> 0xB6
    0x7A -> 0xDA
    0x7B -> 0x21
    0x7C -> 0x10
    0x7D -> 0xFF
    0x7E -> 0xF3
    0x7F -> 0xD2
    0x80 -> 0xCD
    0x81 -> 0x0C
    0x82 -> 0x13
    0x83 -> 0xEC
    0x84 -> 0x5F
    0x85 -> 0x97
    0x86 -> 0x44
    0x87 -> 0x17
    0x88 -> 0xC4
    0x89 -> 0xA7
    0x8A -> 0x7E
    0x8B -> 0x3D
    0x8C -> 0x64
    0x8D -> 0x5D
    0x8E -> 0x19
    0x8F -> 0x73
    0x90 -> 0x60
    0x91 -> 0x81
    0x92 -> 0x4F
    0x93 -> 0xDC
    0x94 -> 0x22
    0x95 -> 0x2A
    0x96 -> 0x90
    0x97 -> 0x88
    0x98 -> 0x46
    0x99 -> 0xEE
    0x9A -> 0xB8
    0x9B -> 0x14
    0x9C -> 0xDE
    0x9D -> 0x5E
    0x9E -> 0x0B
    0x9F -> 0xDB
    0xA0 -> 0xE0
    0xA1 -> 0x32
    0xA2 -> 0x3A
    0xA3 -> 0x0A
    0xA4 -> 0x49
    0xA5 -> 0x06
    0xA6 -> 0x24
    0xA7 -> 0x5C
    0xA8 -> 0xC2
    0xA9 -> 0xD3
    0xAA -> 0xAC
    0xAB -> 0x62
    0xAC -> 0x91
    0xAD -> 0x95
    0xAE -> 0xE4
    0xAF -> 0x79
    0xB0 -> 0xE7
    0xB1 -> 0xC8
    0xB2 -> 0x37
    0xB3 -> 0x6D
    0xB4 -> 0x8D
    0xB5 -> 0xD5
    0xB6 -> 0x4E
    0xB7 -> 0xA9
    0xB8 -> 0x6C
    0xB9 -> 0x56
    0xBA -> 0xF4
    0xBB -> 0xEA
    0xBC -> 0x65
    0xBD -> 0x7A
    0xBE -> 0xAE
    0xBF -> 0x08
    0xC0 -> 0xBA
    0xC1 -> 0x78
    0xC2 -> 0x25
    0xC3 -> 0x2E
    0xC4 -> 0x1C
    0xC5 -> 0xA6
    0xC6 -> 0xB4
    0xC7 -> 0xC6
    0xC8 -> 0xE8
    0xC9 -> 0xDD
    0xCA -> 0x74
    0xCB -> 0x1F
    0xCC -> 0x4B
    0xCD -> 0xBD
    0xCE -> 0x8B
    0xCF -> 0x8A
    0xD0 -> 0x70
    0xD1 -> 0x3E
    0xD2 -> 0xB5
    0xD3 -> 0x66
    0xD4 -> 0x48
    0xD5 -> 0x03
    0xD6 -> 0xF6
    0xD7 -> 0x0E
    0xD8 -> 0x61
    0xD9 -> 0x35
    0xDA -> 0x57
    0xDB -> 0xB9
    0xDC -> 0x86
    0xDD -> 0xC1
    0xDE -> 0x1D
    0xDF -> 0x9E
    0xE0 -> 0xE1
    0xE1 -> 0xF8
    0xE2 -> 0x98
    0xE3 -> 0x11
    0xE4 -> 0x69
    0xE5 -> 0xD9
    0xE6 -> 0x8E
    0xE7 -> 0x94
    0xE8 -> 0x9B
    0xE9 -> 0x1E
    0xEA -> 0x87
    0xEB -> 0xE9
    0xEC -> 0xCE
    0xED -> 0x55
    0xEE -> 0x28
    0xEF -> 0xDF
    0xF0 -> 0x8C
    0xF1 -> 0xA1
    0xF2 -> 0x89
    0xF3 -> 0x0D
    0xF4 -> 0xBF
    0xF5 -> 0xE6
    0xF6 -> 0x42
    0xF7 -> 0x68
    0xF8 -> 0x41
    0xF9 -> 0x99
    0xFA -> 0x2D
    0xFB -> 0x0F
    0xFC -> 0xB0
    0xFD -> 0x54
    0xFE -> 0xBB
    _ -> 0x16
  }
}
