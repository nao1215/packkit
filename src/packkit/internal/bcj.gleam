//// Branch / Call / Jump filters for xz (and friends).
////
//// BCJ filters are pre-processors that, before compression, rewrite
//// the relative jump / call offsets in machine code to absolute
//// targets.  The result has more redundancy (repeated call targets
//// instead of varying displacements) and compresses better.  At
//// decode time the inverse transform converts the absolute targets
//// back to relative displacements so the resulting bytes match the
//// original binary.
////
//// The algorithms here mirror the xz-utils reference implementation
//// (`src/liblzma/simple/{x86,arm,arm64,armthumb,ia64,powerpc,riscv,
//// sparc}.c`, 0BSD licensed).  Implementations are written from the
//// algorithm description, not copied; the reference is consulted to
//// confirm edge cases such as the x86 `prev_mask` state machine.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list

const mask32: Int = 0xFFFFFFFF

/// Decode an x86 BCJ-encoded byte sequence.
///
/// `start_offset` is the position the encoder used as its
/// `now_pos` — for xz blocks this is always 0 because each xz
/// block resets BCJ state.
pub fn x86_decode(
  bytes bytes: BitArray,
  start_offset start_offset: Int,
) -> BitArray {
  let total = bit_array.byte_size(bytes)
  case total < 5 {
    True -> bytes
    False -> {
      let byte_list = bit_array_to_byte_list(bytes, [])
      let initial =
        X86State(
          // The reference initialises prev_pos to "now_pos - 5" so
          // the first opcode always sees `offset > 5` and resets
          // prev_mask.
          prev_pos: start_offset - 5,
          prev_mask: 0,
        )
      let limit = total - 5
      let decoded =
        x86_decode_loop(byte_list, 0, limit, start_offset, initial, [])
      byte_list_to_bit_array(decoded, <<>>)
    }
  }
}

type X86State {
  X86State(prev_pos: Int, prev_mask: Int)
}

fn x86_decode_loop(
  remaining: List(Int),
  buffer_pos: Int,
  limit: Int,
  now_pos: Int,
  state: X86State,
  acc_reversed: List(Int),
) -> List(Int) {
  case remaining {
    [] -> list.reverse(acc_reversed)
    [byte_at_pos, ..rest] -> {
      case buffer_pos > limit {
        True ->
          // Less than 5 bytes left from this position — flush the
          // rest verbatim.
          list.append(list.reverse(acc_reversed), remaining)
        False ->
          case byte_at_pos {
            0xE8 | 0xE9 ->
              x86_try_decode_call(
                remaining,
                buffer_pos,
                limit,
                now_pos,
                state,
                acc_reversed,
              )
            _ ->
              x86_decode_loop(rest, buffer_pos + 1, limit, now_pos, state, [
                byte_at_pos,
                ..acc_reversed
              ])
          }
      }
    }
  }
}

fn x86_try_decode_call(
  remaining: List(Int),
  buffer_pos: Int,
  limit: Int,
  now_pos: Int,
  state: X86State,
  acc_reversed: List(Int),
) -> List(Int) {
  // Update prev_mask based on distance since the previous opcode.
  let offset = now_pos + buffer_pos - state.prev_pos
  let prev_pos_after = now_pos + buffer_pos
  let prev_mask_after = case offset > 5 {
    True -> 0
    False -> shift_mask_left(state.prev_mask, offset)
  }

  // The `buffer_pos > limit` guard above already ensures we have
  // at least 5 bytes left, so the match below is exhaustive.
  let #(opcode, d0, d1, d2, d3, tail) = case remaining {
    [op, b0, b1, b2, b3, ..rest] -> #(op, b0, b1, b2, b3, rest)
    _ -> #(0, 0, 0, 0, 0, [])
  }
  case is_decodable(d3, prev_mask_after) {
    False -> {
      // Bump mask bit 0 (and bit 4 when d3 looked like an MS byte).
      let bumped = case test_msb(d3) {
        True -> int.bitwise_or(int.bitwise_or(prev_mask_after, 1), 0x10)
        False -> int.bitwise_or(prev_mask_after, 1)
      }
      x86_decode_loop(
        [d0, d1, d2, d3, ..tail],
        buffer_pos + 1,
        limit,
        now_pos,
        X86State(prev_pos: prev_pos_after, prev_mask: bumped),
        [opcode, ..acc_reversed],
      )
    }
    True -> {
      let src =
        int.bitwise_or(
          int.bitwise_or(
            int.bitwise_shift_left(d3, 24),
            int.bitwise_shift_left(d2, 16),
          ),
          int.bitwise_or(int.bitwise_shift_left(d1, 8), d0),
        )
      let dest =
        x86_resolve_dest(src, now_pos + buffer_pos + 5, prev_mask_after)
      // Per the reference: the high byte of the written displacement
      // is forced to 0x00 if bit 24 of `dest` is 0, else 0xFF.
      let new_d3 = case int.bitwise_and(int.bitwise_shift_right(dest, 24), 1) {
        0 -> 0
        _ -> 0xFF
      }
      let new_d0 = int.bitwise_and(dest, 0xFF)
      let new_d1 = int.bitwise_and(int.bitwise_shift_right(dest, 8), 0xFF)
      let new_d2 = int.bitwise_and(int.bitwise_shift_right(dest, 16), 0xFF)
      x86_decode_loop(
        tail,
        buffer_pos + 5,
        limit,
        now_pos,
        X86State(prev_pos: prev_pos_after, prev_mask: 0),
        [new_d3, new_d2, new_d1, new_d0, opcode, ..acc_reversed],
      )
    }
  }
}

fn is_decodable(byte: Int, prev_mask: Int) -> Bool {
  let mask_top = int.bitwise_shift_right(prev_mask, 1)
  test_msb(byte) && mask_top <= 4 && mask_top != 3
}

fn test_msb(byte: Int) -> Bool {
  byte == 0 || byte == 0xFF
}

fn shift_mask_left(mask: Int, by: Int) -> Int {
  // Equivalent to the reference's `for(i=0; i<offset; i++) { mask &= 0x77; mask <<= 1; }`
  case by {
    0 -> mask
    _ ->
      shift_mask_left(
        int.bitwise_shift_left(int.bitwise_and(mask, 0x77), 1),
        by - 1,
      )
  }
}

fn x86_resolve_dest(src: Int, subtract: Int, prev_mask: Int) -> Int {
  let dest = int.bitwise_and(src - subtract + 0x1_0000_0000, mask32)
  case prev_mask {
    0 -> dest
    _ -> x86_resolve_dest_loop(src, subtract, prev_mask, dest)
  }
}

fn x86_resolve_dest_loop(
  _src: Int,
  subtract: Int,
  prev_mask: Int,
  dest: Int,
) -> Int {
  let bit_number = mask_to_bit_number(int.bitwise_shift_right(prev_mask, 1))
  let probe_byte =
    int.bitwise_and(int.bitwise_shift_right(dest, 24 - bit_number * 8), 0xFF)
  case test_msb(probe_byte) {
    False -> dest
    True -> {
      let xor_mask = case bit_number {
        0 -> mask32
        n -> int.bitwise_and(int.bitwise_shift_left(1, 32 - n * 8) - 1, mask32)
      }
      let new_src = int.bitwise_exclusive_or(dest, xor_mask)
      // The reference reaches break after one re-check; replicate
      // that by terminating after the first iteration.
      int.bitwise_and(new_src - subtract + 0x1_0000_0000, mask32)
    }
  }
}

fn mask_to_bit_number(value: Int) -> Int {
  // `prev_mask >> 1` from the reference; values 0,1,2,3,4 map to
  // 0,1,2,2,3.  Values past 4 never reach this helper.
  case value {
    0 -> 0
    1 -> 1
    2 -> 2
    3 -> 2
    _ -> 3
  }
}

/// Decode a PowerPC (big-endian) BCJ-encoded byte sequence.
/// PowerPC BCJ looks for the branch instruction `0x48` (with
/// link bit set) on 4-byte boundaries and converts the encoder's
/// absolute target back to a word-relative offset.
pub fn powerpc_decode(
  bytes bytes: BitArray,
  start_offset start_offset: Int,
) -> BitArray {
  let total = bit_array.byte_size(bytes)
  let aligned = total - { total % 4 }
  case aligned {
    0 -> bytes
    _ ->
      case
        bit_array.slice(bytes, 0, aligned),
        bit_array.slice(bytes, aligned, total - aligned)
      {
        Ok(head), Ok(tail) -> {
          let body = powerpc_decode_words(head, start_offset, 0, <<>>)
          bit_array.concat([body, tail])
        }
        _, _ -> bytes
      }
  }
}

fn powerpc_decode_words(
  bytes: BitArray,
  start_offset: Int,
  word_index: Int,
  acc: BitArray,
) -> BitArray {
  case bytes {
    // PowerPC branch+link: 0x48000001 with sign-extended 24-bit
    // displacement.  High byte's top 6 bits = 0x12 (== 0x48 >> 2),
    // low byte's bottom 2 bits = 0b01 (Abs=0, Link=1).  The
    // bitwise checks aren't valid in a `case` guard so we
    // dispatch through a helper.
    <<b0, b1, b2, b3, rest:bytes>> ->
      case is_powerpc_branch_link(b0, b3) {
        False ->
          powerpc_decode_words(
            rest,
            start_offset,
            word_index + 1,
            bit_array.concat([acc, <<b0, b1, b2, b3>>]),
          )
        True ->
          powerpc_apply(b0, b1, b2, b3, rest, start_offset, word_index, acc)
      }
    _ -> acc
  }
}

fn is_powerpc_branch_link(b0: Int, b3: Int) -> Bool {
  int.bitwise_shift_right(b0, 2) == 0x12 && int.bitwise_and(b3, 3) == 1
}

fn powerpc_apply(
  b0: Int,
  b1: Int,
  b2: Int,
  b3: Int,
  rest: BitArray,
  start_offset: Int,
  word_index: Int,
  acc: BitArray,
) -> BitArray {
  let src =
    int.bitwise_or(
      int.bitwise_or(
        int.bitwise_shift_left(int.bitwise_and(b0, 3), 24),
        int.bitwise_shift_left(b1, 16),
      ),
      int.bitwise_or(
        int.bitwise_shift_left(b2, 8),
        // b3 with the bottom 2 bits cleared (~3 == 0xFC).
        int.bitwise_and(b3, 0xFC),
      ),
    )
  let dest =
    int.bitwise_and(
      src - { start_offset + word_index * 4 } + 0x1_0000_0000,
      mask32,
    )
  let new_b0 =
    int.bitwise_or(
      0x48,
      int.bitwise_and(int.bitwise_shift_right(dest, 24), 0x03),
    )
  let new_b1 = int.bitwise_and(int.bitwise_shift_right(dest, 16), 0xFF)
  let new_b2 = int.bitwise_and(int.bitwise_shift_right(dest, 8), 0xFF)
  let new_b3 =
    int.bitwise_or(int.bitwise_and(b3, 0x03), int.bitwise_and(dest, 0xFC))
  powerpc_decode_words(
    rest,
    start_offset,
    word_index + 1,
    bit_array.concat([acc, <<new_b0, new_b1, new_b2, new_b3>>]),
  )
}

/// Decode an ARM-Thumb (T32) BCJ-encoded byte sequence.  Thumb-2
/// `BL` / `BLX` instructions span two 16-bit half-words; the
/// encoder rewrites the relative branch target to absolute byte
/// addresses and the decoder reverses that.
pub fn armthumb_decode(
  bytes bytes: BitArray,
  start_offset start_offset: Int,
) -> BitArray {
  let total = bit_array.byte_size(bytes)
  case total < 4 {
    True -> bytes
    False -> armthumb_decode_loop(bytes, start_offset, 0, total - 4, <<>>)
  }
}

fn armthumb_decode_loop(
  remaining: BitArray,
  start_offset: Int,
  pos: Int,
  limit: Int,
  acc: BitArray,
) -> BitArray {
  case pos > limit {
    True -> bit_array.concat([acc, remaining])
    False ->
      case remaining {
        <<b0, b1, b2, b3, rest:bytes>> ->
          case is_armthumb_bl(b1, b3) {
            True ->
              armthumb_apply(
                b0,
                b1,
                b2,
                b3,
                rest,
                start_offset,
                pos,
                limit,
                acc,
              )
            False ->
              // No match — advance only by 2 bytes.  Emit b0 + b1
              // to the output, then continue scanning from b2.
              armthumb_decode_loop(
                bit_array.concat([<<b2, b3>>, rest]),
                start_offset,
                pos + 2,
                limit,
                bit_array.concat([acc, <<b0, b1>>]),
              )
          }
        _ -> bit_array.concat([acc, remaining])
      }
  }
}

fn is_armthumb_bl(b1: Int, b3: Int) -> Bool {
  int.bitwise_and(b1, 0xF8) == 0xF0 && int.bitwise_and(b3, 0xF8) == 0xF8
}

fn armthumb_apply(
  b0: Int,
  b1: Int,
  b2: Int,
  b3: Int,
  rest: BitArray,
  start_offset: Int,
  pos: Int,
  limit: Int,
  acc: BitArray,
) -> BitArray {
  let src =
    int.bitwise_or(
      int.bitwise_or(
        int.bitwise_shift_left(int.bitwise_and(b1, 7), 19),
        int.bitwise_shift_left(b0, 11),
      ),
      int.bitwise_or(int.bitwise_shift_left(int.bitwise_and(b3, 7), 8), b2),
    )
  let src_bytes = int.bitwise_shift_left(src, 1)
  let dest =
    int.bitwise_and(
      src_bytes - { start_offset + pos + 4 } + 0x1_0000_0000,
      mask32,
    )
    |> int.bitwise_shift_right(1)
  let new_b1 =
    int.bitwise_or(
      0xF0,
      int.bitwise_and(int.bitwise_shift_right(dest, 19), 0x07),
    )
  let new_b0 = int.bitwise_and(int.bitwise_shift_right(dest, 11), 0xFF)
  let new_b3 =
    int.bitwise_or(
      0xF8,
      int.bitwise_and(int.bitwise_shift_right(dest, 8), 0x07),
    )
  let new_b2 = int.bitwise_and(dest, 0xFF)
  armthumb_decode_loop(
    rest,
    start_offset,
    pos + 4,
    limit,
    bit_array.concat([acc, <<new_b0, new_b1, new_b2, new_b3>>]),
  )
}

/// Decode a SPARC BCJ-encoded byte sequence.  SPARC's
/// branch-with-link instructions sit on 4-byte boundaries and
/// match either `40 [00..3F] ...` (CALL with positive offset
/// candidate) or `7F [C0..FF] ...` (CALL with negative offset
/// candidate); the rewritten 30-bit displacement is sign-
/// extended back from its 22-bit truncated form during decode.
pub fn sparc_decode(
  bytes bytes: BitArray,
  start_offset start_offset: Int,
) -> BitArray {
  let total = bit_array.byte_size(bytes)
  let aligned = total - { total % 4 }
  case aligned {
    0 -> bytes
    _ ->
      case
        bit_array.slice(bytes, 0, aligned),
        bit_array.slice(bytes, aligned, total - aligned)
      {
        Ok(head), Ok(tail) -> {
          let body = sparc_decode_words(head, start_offset, 0, <<>>)
          bit_array.concat([body, tail])
        }
        _, _ -> bytes
      }
  }
}

fn sparc_decode_words(
  bytes: BitArray,
  start_offset: Int,
  word_index: Int,
  acc: BitArray,
) -> BitArray {
  case bytes {
    <<b0, b1, b2, b3, rest:bytes>> ->
      case is_sparc_call(b0, b1) {
        True -> sparc_apply(b0, b1, b2, b3, rest, start_offset, word_index, acc)
        False ->
          sparc_decode_words(
            rest,
            start_offset,
            word_index + 1,
            bit_array.concat([acc, <<b0, b1, b2, b3>>]),
          )
      }
    _ -> acc
  }
}

fn is_sparc_call(b0: Int, b1: Int) -> Bool {
  { b0 == 0x40 && int.bitwise_and(b1, 0xC0) == 0x00 }
  || { b0 == 0x7F && int.bitwise_and(b1, 0xC0) == 0xC0 }
}

fn sparc_apply(
  b0: Int,
  b1: Int,
  b2: Int,
  b3: Int,
  rest: BitArray,
  start_offset: Int,
  word_index: Int,
  acc: BitArray,
) -> BitArray {
  let src =
    int.bitwise_or(
      int.bitwise_or(
        int.bitwise_shift_left(b0, 24),
        int.bitwise_shift_left(b1, 16),
      ),
      int.bitwise_or(int.bitwise_shift_left(b2, 8), b3),
    )
    |> int.bitwise_shift_left(2)
    |> int.bitwise_and(mask32)
  let dest =
    int.bitwise_and(
      src - { start_offset + word_index * 4 } + 0x1_0000_0000,
      mask32,
    )
    |> int.bitwise_shift_right(2)
  // Reference: `(((0 - ((dest >> 22) & 1)) << 22) & 0x3FFFFFFF)
  //              | (dest & 0x3FFFFF) | 0x40000000`.
  // The first term replicates the sign bit (bit 22) across the
  // upper part of the 30-bit field.
  let sign_bit = int.bitwise_and(int.bitwise_shift_right(dest, 22), 1)
  let sign_word = case sign_bit {
    0 -> 0
    _ -> 0x1_0000_0000 - 1
  }
  let sign_ext =
    int.bitwise_and(int.bitwise_shift_left(sign_word, 22), 0x3FFFFFFF)
    |> int.bitwise_and(mask32)
  let combined =
    int.bitwise_or(
      int.bitwise_or(sign_ext, int.bitwise_and(dest, 0x3FFFFF)),
      0x40000000,
    )
  let new_b0 = int.bitwise_and(int.bitwise_shift_right(combined, 24), 0xFF)
  let new_b1 = int.bitwise_and(int.bitwise_shift_right(combined, 16), 0xFF)
  let new_b2 = int.bitwise_and(int.bitwise_shift_right(combined, 8), 0xFF)
  let new_b3 = int.bitwise_and(combined, 0xFF)
  sparc_decode_words(
    rest,
    start_offset,
    word_index + 1,
    bit_array.concat([acc, <<new_b0, new_b1, new_b2, new_b3>>]),
  )
}

/// Decode an ARM64 BCJ-encoded byte sequence.  Two ARM64
/// instruction classes are rewritten by the BCJ filter:
///
/// * `BL` (top 6 bits = 0x25): full 26-bit immediate is
///   converted (±128 MiB range).
/// * `ADRP` (top 8 bits match 0x9F mask == 0x90): 21-bit
///   immediate is converted, but only when the encoded value
///   stays inside ±512 MiB to reduce false positives.
///
/// All instructions are 32-bit little-endian on 4-byte
/// boundaries.
pub fn arm64_decode(
  bytes bytes: BitArray,
  start_offset start_offset: Int,
) -> BitArray {
  let total = bit_array.byte_size(bytes)
  let aligned = total - { total % 4 }
  case aligned {
    0 -> bytes
    _ ->
      case
        bit_array.slice(bytes, 0, aligned),
        bit_array.slice(bytes, aligned, total - aligned)
      {
        Ok(head), Ok(tail) -> {
          let body = arm64_decode_words(head, start_offset, 0, <<>>)
          bit_array.concat([body, tail])
        }
        _, _ -> bytes
      }
  }
}

fn arm64_decode_words(
  bytes: BitArray,
  start_offset: Int,
  word_index: Int,
  acc: BitArray,
) -> BitArray {
  case bytes {
    <<b0, b1, b2, b3, rest:bytes>> -> {
      let instr =
        int.bitwise_or(
          int.bitwise_or(
            int.bitwise_shift_left(b3, 24),
            int.bitwise_shift_left(b2, 16),
          ),
          int.bitwise_or(int.bitwise_shift_left(b1, 8), b0),
        )
      let pc = start_offset + word_index * 4
      case classify_arm64_instr(instr) {
        Arm64Bl -> {
          let new_instr = arm64_bl_decode(instr, pc)
          arm64_decode_words(
            rest,
            start_offset,
            word_index + 1,
            bit_array.concat([acc, write_le32(new_instr)]),
          )
        }
        Arm64Adrp ->
          case arm64_adrp_decode(instr, pc) {
            Ok(new_instr) ->
              arm64_decode_words(
                rest,
                start_offset,
                word_index + 1,
                bit_array.concat([acc, write_le32(new_instr)]),
              )
            Error(Nil) ->
              arm64_decode_words(
                rest,
                start_offset,
                word_index + 1,
                bit_array.concat([acc, <<b0, b1, b2, b3>>]),
              )
          }
        Arm64Other ->
          arm64_decode_words(
            rest,
            start_offset,
            word_index + 1,
            bit_array.concat([acc, <<b0, b1, b2, b3>>]),
          )
      }
    }
    _ -> acc
  }
}

type Arm64Kind {
  Arm64Bl
  Arm64Adrp
  Arm64Other
}

fn classify_arm64_instr(instr: Int) -> Arm64Kind {
  case int.bitwise_shift_right(instr, 26) {
    0x25 -> Arm64Bl
    _ ->
      case int.bitwise_and(instr, 0x9F000000) == 0x90000000 {
        True -> Arm64Adrp
        False -> Arm64Other
      }
  }
}

fn arm64_bl_decode(instr: Int, pc: Int) -> Int {
  // BL decode: new_instr = 0x94000000 | ((src + (-pc>>2)) & 0x03FFFFFF)
  let pc_words = int.bitwise_shift_right(pc, 2)
  let neg_pc = int.bitwise_and(0x1_0000_0000 - pc_words, mask32)
  int.bitwise_or(0x94000000, int.bitwise_and(instr + neg_pc, 0x03FFFFFF))
  |> int.bitwise_and(mask32)
}

fn arm64_adrp_decode(instr: Int, pc: Int) -> Result(Int, Nil) {
  let src =
    int.bitwise_or(
      int.bitwise_and(int.bitwise_shift_right(instr, 29), 3),
      int.bitwise_and(int.bitwise_shift_right(instr, 3), 0x001FFFFC),
    )
  // Range check: reject conversion when the encoded value falls
  // outside the ±512 MiB window.  Matches the reference's
  // `(src + 0x00020000) & 0x001C0000` non-zero test.
  case int.bitwise_and(src + 0x00020000, 0x001C0000) {
    0 -> Ok(arm64_adrp_apply(instr, src, pc))
    _ -> Error(Nil)
  }
}

fn arm64_adrp_apply(instr: Int, src: Int, pc: Int) -> Int {
  let pc_pages = int.bitwise_shift_right(pc, 12)
  let neg_pc = int.bitwise_and(0x1_0000_0000 - pc_pages, mask32)
  let dest = int.bitwise_and(src + neg_pc, mask32)
  let base = int.bitwise_and(instr, 0x9000001F)
  let high_immlo = int.bitwise_shift_left(int.bitwise_and(dest, 3), 29)
  let mid_immhi = int.bitwise_shift_left(int.bitwise_and(dest, 0x0003FFFC), 3)
  let sign_replica =
    int.bitwise_and(
      0x1_0000_0000 - int.bitwise_and(dest, 0x00020000),
      0x00E00000,
    )
  int.bitwise_or(
    int.bitwise_or(base, high_immlo),
    int.bitwise_or(mid_immhi, sign_replica),
  )
  |> int.bitwise_and(mask32)
}

fn write_le32(value: Int) -> BitArray {
  let masked = int.bitwise_and(value, mask32)
  <<
    int.bitwise_and(masked, 0xFF),
    int.bitwise_and(int.bitwise_shift_right(masked, 8), 0xFF),
    int.bitwise_and(int.bitwise_shift_right(masked, 16), 0xFF),
    int.bitwise_and(int.bitwise_shift_right(masked, 24), 0xFF),
  >>
}

/// Decode an ARM (A32) BCJ-encoded byte sequence.  ARM BCJ looks
/// for `BL` (branch-with-link) instructions on 4-byte boundaries:
/// the high byte is `0xEB` and the low 24 bits are the
/// (word-aligned) relative target.  The encoder rewrites the
/// target to an absolute byte address; the decoder converts back.
pub fn arm_decode(
  bytes bytes: BitArray,
  start_offset start_offset: Int,
) -> BitArray {
  let total = bit_array.byte_size(bytes)
  let aligned = total - { total % 4 }
  case aligned {
    0 -> bytes
    _ ->
      case
        bit_array.slice(bytes, 0, aligned),
        bit_array.slice(bytes, aligned, total - aligned)
      {
        Ok(head), Ok(tail) -> {
          let body = arm_decode_words(head, start_offset, 0, <<>>)
          bit_array.concat([body, tail])
        }
        _, _ -> bytes
      }
  }
}

fn arm_decode_words(
  bytes: BitArray,
  start_offset: Int,
  word_index: Int,
  acc: BitArray,
) -> BitArray {
  case bytes {
    <<b0, b1, b2, 0xEB, rest:bytes>> -> {
      let src =
        int.bitwise_or(
          int.bitwise_or(
            int.bitwise_shift_left(b2, 16),
            int.bitwise_shift_left(b1, 8),
          ),
          b0,
        )
      let src_words = int.bitwise_shift_left(src, 2)
      let abs_byte_target = int.bitwise_and(src_words, mask32)
      let new_target_bytes =
        int.bitwise_and(
          abs_byte_target
            - { start_offset + word_index * 4 + 8 }
            + 0x1_0000_0000,
          mask32,
        )
      let new_src = int.bitwise_shift_right(new_target_bytes, 2)
      let new_b0 = int.bitwise_and(new_src, 0xFF)
      let new_b1 = int.bitwise_and(int.bitwise_shift_right(new_src, 8), 0xFF)
      let new_b2 = int.bitwise_and(int.bitwise_shift_right(new_src, 16), 0xFF)
      arm_decode_words(
        rest,
        start_offset,
        word_index + 1,
        bit_array.concat([acc, <<new_b0, new_b1, new_b2, 0xEB>>]),
      )
    }
    <<b0, b1, b2, b3, rest:bytes>> ->
      arm_decode_words(
        rest,
        start_offset,
        word_index + 1,
        bit_array.concat([acc, <<b0, b1, b2, b3>>]),
      )
    _ -> acc
  }
}

fn bit_array_to_byte_list(bytes: BitArray, acc: List(Int)) -> List(Int) {
  case bytes {
    <<b, rest:bytes>> -> bit_array_to_byte_list(rest, [b, ..acc])
    _ -> list.reverse(acc)
  }
}

fn byte_list_to_bit_array(bytes: List(Int), acc: BitArray) -> BitArray {
  case bytes {
    [] -> acc
    [b, ..rest] -> byte_list_to_bit_array(rest, <<acc:bits, b>>)
  }
}

// ---------- IA-64 (Itanium) BCJ ----------

/// Decode an IA-64 BCJ-encoded byte sequence.  IA-64 bundles three
/// instructions in a 128-bit (16-byte) chunk.  Each bundle starts
/// with a 5-bit template selector that determines whether each of
/// the three 41-bit slots may hold an IP-relative branch; the
/// pre-computed branch table mirrors xz-utils.  For every slot that
/// could hold a branch (B-unit branch with major opcode 0x5 and
/// the constant operand field zero) the 21-bit IP-relative target
/// is converted to / from the absolute byte address.
pub fn ia64_decode(
  bytes bytes: BitArray,
  start_offset start_offset: Int,
) -> BitArray {
  let total = bit_array.byte_size(bytes)
  let aligned = total - { total % 16 }
  case aligned {
    0 -> bytes
    _ ->
      case
        bit_array.slice(bytes, 0, aligned),
        bit_array.slice(bytes, aligned, total - aligned)
      {
        Ok(head), Ok(tail) -> {
          let body = ia64_decode_bundles(head, start_offset, 0, <<>>)
          bit_array.concat([body, tail])
        }
        _, _ -> bytes
      }
  }
}

fn ia64_decode_bundles(
  bytes: BitArray,
  start_offset: Int,
  bundle_index: Int,
  acc: BitArray,
) -> BitArray {
  case bytes {
    <<bundle:bytes-size(16), rest:bytes>> -> {
      let now_pos = start_offset + bundle_index * 16
      let new_bundle = ia64_decode_bundle(bundle, now_pos)
      ia64_decode_bundles(
        rest,
        start_offset,
        bundle_index + 1,
        bit_array.concat([acc, new_bundle]),
      )
    }
    _ -> acc
  }
}

fn ia64_decode_bundle(bundle: BitArray, now_pos: Int) -> BitArray {
  case bundle {
    <<b0, _:bytes>> -> {
      let template = int.bitwise_and(b0, 0x1F)
      let mask = ia64_branch_mask(template)
      case mask {
        0 -> bundle
        _ -> {
          let byte_list = bit_array_to_byte_list(bundle, [])
          let updated = ia64_process_slots(byte_list, mask, 0, 5, now_pos)
          byte_list_to_bit_array(updated, <<>>)
        }
      }
    }
    _ -> bundle
  }
}

fn ia64_branch_mask(template: Int) -> Int {
  case template {
    16 | 17 | 24 | 25 | 28 | 29 -> 4
    18 | 19 -> 6
    22 | 23 -> 7
    _ -> 0
  }
}

fn ia64_process_slots(
  bytes_list: List(Int),
  mask: Int,
  slot: Int,
  bit_pos: Int,
  now_pos: Int,
) -> List(Int) {
  use <- bool.guard(when: slot >= 3, return: bytes_list)
  let slot_active = int.bitwise_and(int.bitwise_shift_right(mask, slot), 1) == 1
  let updated = case slot_active {
    True -> ia64_process_slot(bytes_list, bit_pos, now_pos)
    False -> bytes_list
  }
  ia64_process_slots(updated, mask, slot + 1, bit_pos + 41, now_pos)
}

fn ia64_process_slot(
  bytes_list: List(Int),
  bit_pos: Int,
  now_pos: Int,
) -> List(Int) {
  let byte_pos = int.bitwise_shift_right(bit_pos, 3)
  let bit_res = int.bitwise_and(bit_pos, 7)
  let six = list_take_range(bytes_list, byte_pos, 6)
  case list.length(six) == 6 {
    False -> bytes_list
    True -> {
      let instruction = ia64_read_le48(six, 0, 0)
      let inst_norm = int.bitwise_shift_right(instruction, bit_res)
      let major = int.bitwise_and(int.bitwise_shift_right(inst_norm, 37), 0xF)
      let middle = int.bitwise_and(int.bitwise_shift_right(inst_norm, 9), 0x7)
      case major == 0x5 && middle == 0 {
        False -> bytes_list
        True -> {
          let src_lo =
            int.bitwise_and(int.bitwise_shift_right(inst_norm, 13), 0xFFFFF)
          let src_hi_bit =
            int.bitwise_and(int.bitwise_shift_right(inst_norm, 36), 1)
          let src = int.bitwise_shift_left(src_lo + src_hi_bit * 0x100000, 4)
          let dest_byte = int.bitwise_and(src - now_pos + 0x1_0000_0000, mask32)
          let dest = int.bitwise_shift_right(dest_byte, 4)
          let new_inst_norm = ia64_rewrite_inst_norm(inst_norm, dest)
          let low_mask = int.bitwise_shift_left(1, bit_res) - 1
          let preserved = int.bitwise_and(instruction, low_mask)
          let new_instruction =
            preserved + int.bitwise_shift_left(new_inst_norm, bit_res)
          let new_six = ia64_write_le48(new_instruction, 6, [])
          list_replace_range(bytes_list, byte_pos, new_six)
        }
      }
    }
  }
}

fn ia64_rewrite_inst_norm(inst_norm: Int, dest: Int) -> Int {
  // Clear bits 13-32 (mask 0xFFFFF << 13) and bit 36 (mask 1 << 36)
  // and write dest's low 20 bits to [32:13] and dest's bit 20 to [36].
  let clear_lo20 = int.bitwise_shift_left(0xFFFFF, 13)
  let clear_bit36 = int.bitwise_shift_left(1, 36)
  let clear_mask = int.bitwise_not(int.bitwise_or(clear_lo20, clear_bit36))
  let cleared = int.bitwise_and(inst_norm, clear_mask)
  let dest_lo20 = int.bitwise_shift_left(int.bitwise_and(dest, 0xFFFFF), 13)
  let dest_bit20 = int.bitwise_shift_left(int.bitwise_and(dest, 0x100000), 16)
  int.bitwise_or(cleared, int.bitwise_or(dest_lo20, dest_bit20))
}

fn ia64_read_le48(bytes: List(Int), index: Int, acc: Int) -> Int {
  case bytes {
    [] -> acc
    [b, ..rest] -> {
      let next = acc + int.bitwise_shift_left(b, 8 * index)
      ia64_read_le48(rest, index + 1, next)
    }
  }
}

fn ia64_write_le48(value: Int, remaining: Int, acc: List(Int)) -> List(Int) {
  case remaining {
    0 -> list.reverse(acc)
    _ -> {
      let byte = int.bitwise_and(value, 0xFF)
      ia64_write_le48(int.bitwise_shift_right(value, 8), remaining - 1, [
        byte,
        ..acc
      ])
    }
  }
}

fn list_take_range(items: List(Int), start: Int, count: Int) -> List(Int) {
  case start {
    0 -> list_take_n(items, count, [])
    _ ->
      case items {
        [] -> []
        [_, ..rest] -> list_take_range(rest, start - 1, count)
      }
  }
}

fn list_take_n(items: List(Int), count: Int, acc: List(Int)) -> List(Int) {
  case count, items {
    0, _ -> list.reverse(acc)
    _, [] -> list.reverse(acc)
    _, [b, ..rest] -> list_take_n(rest, count - 1, [b, ..acc])
  }
}

fn list_replace_range(
  items: List(Int),
  start: Int,
  replacement: List(Int),
) -> List(Int) {
  case start {
    0 -> list_replace_head(items, replacement)
    _ ->
      case items {
        [] -> []
        [head, ..rest] -> [
          head,
          ..list_replace_range(rest, start - 1, replacement)
        ]
      }
  }
}

fn list_replace_head(items: List(Int), replacement: List(Int)) -> List(Int) {
  case replacement {
    [] -> items
    [r, ..rest_rep] ->
      case items {
        [] -> []
        [_, ..rest] -> [r, ..list_replace_head(rest, rest_rep)]
      }
  }
}

// ---------- RISC-V BCJ ----------

/// Decode a RISC-V BCJ-encoded byte sequence.  This implements the
/// xz-utils RISC-V filter (Lasse Collin / Jia Tan, 0BSD).
///
/// The filter rewrites two instruction kinds:
///
///   - **JAL** (opcode 0x6F, byte 0xEF) with rd in {x1, x5} —
///     a 20-bit PC-relative call.  The encoder packs the absolute
///     target as a big-endian 24-bit number in bytes [3..1]; the
///     decoder reverses it back to the J-type immediate scrambled
///     across b1/b2/b3.
///   - **AUIPC + inst2** pairs where AUIPC's rd is not x0 / x2.
///     The encoder rewrites the 8-byte pair into a special form
///     (rd=x2, low 20 bits of inst2 in the high 20 bits of AUIPC,
///     then the absolute 32-bit address in big-endian for the inst2
///     slot).  The decoder restores the original AUIPC immediate
///     and inst2 immediate.
///
/// AUIPC with rd==x0/x2 hits the bijective "fake" code path; it
/// rewrites a special-format byte sequence back to the inverse of
/// the encoder's "fake" conversion so the filter remains safe to
/// apply to arbitrary data.
pub fn riscv_decode(
  bytes bytes: BitArray,
  start_offset start_offset: Int,
) -> BitArray {
  let aligned_start = int.bitwise_and(start_offset, mask32 - 1)
  let total = bit_array.byte_size(bytes)
  case total < 8 {
    True -> bytes
    False -> {
      let byte_list = bit_array_to_byte_list(bytes, [])
      let decoded = riscv_decode_loop(byte_list, 0, total - 8, aligned_start)
      byte_list_to_bit_array(decoded, <<>>)
    }
  }
}

fn riscv_decode_loop(
  bytes_list: List(Int),
  pos: Int,
  limit: Int,
  start_offset: Int,
) -> List(Int) {
  use <- bool.guard(when: pos > limit, return: bytes_list)
  let #(updated, advance) = riscv_step(bytes_list, pos, start_offset)
  riscv_decode_loop(updated, pos + advance, limit, start_offset)
}

fn riscv_step(
  bytes_list: List(Int),
  pos: Int,
  start_offset: Int,
) -> #(List(Int), Int) {
  let slice = list_take_range(bytes_list, pos, 8)
  case slice {
    [b0, b1, b2, b3, b4, b5, b6, b7] ->
      case b0 {
        0xEF -> riscv_decode_jal(bytes_list, pos, b1, b2, b3, start_offset)
        _ ->
          case int.bitwise_and(b0, 0x7F) == 0x17 {
            True ->
              riscv_decode_auipc(
                bytes_list,
                pos,
                b0,
                b1,
                b2,
                b3,
                b4,
                b5,
                b6,
                b7,
                start_offset,
              )
            False -> #(bytes_list, 2)
          }
      }
    _ -> #(bytes_list, 2)
  }
}

fn riscv_decode_jal(
  bytes_list: List(Int),
  pos: Int,
  b1: Int,
  b2: Int,
  b3: Int,
  start_offset: Int,
) -> #(List(Int), Int) {
  case int.bitwise_and(b1, 0x0D) {
    0 -> {
      let pc = start_offset + pos
      let addr_a = int.bitwise_shift_left(int.bitwise_and(b1, 0xF0), 13)
      let addr_b = int.bitwise_shift_left(b2, 9)
      let addr_c = int.bitwise_shift_left(b3, 1)
      let addr =
        int.bitwise_and(addr_a + addr_b + addr_c - pc + 0x1_0000_0000, mask32)
      let new_b1 =
        int.bitwise_or(
          int.bitwise_and(b1, 0x0F),
          int.bitwise_and(int.bitwise_shift_right(addr, 8), 0xF0),
        )
      let new_b2 =
        int.bitwise_or(
          int.bitwise_or(
            int.bitwise_and(int.bitwise_shift_right(addr, 16), 0x0F),
            int.bitwise_and(int.bitwise_shift_right(addr, 7), 0x10),
          ),
          int.bitwise_and(int.bitwise_shift_left(addr, 4), 0xE0),
        )
      let new_b3 =
        int.bitwise_or(
          int.bitwise_and(int.bitwise_shift_right(addr, 4), 0x7F),
          int.bitwise_and(int.bitwise_shift_right(addr, 13), 0x80),
        )
      let updated =
        list_replace_range(bytes_list, pos + 1, [new_b1, new_b2, new_b3])
      #(updated, 4)
    }
    _ -> #(bytes_list, 2)
  }
}

fn riscv_decode_auipc(
  bytes_list: List(Int),
  pos: Int,
  b0: Int,
  b1: Int,
  b2: Int,
  b3: Int,
  b4: Int,
  b5: Int,
  b6: Int,
  b7: Int,
  start_offset: Int,
) -> #(List(Int), Int) {
  let inst =
    b0
    + int.bitwise_shift_left(b1, 8)
    + int.bitwise_shift_left(b2, 16)
    + int.bitwise_shift_left(b3, 24)
  let inst2_le =
    b4
    + int.bitwise_shift_left(b5, 8)
    + int.bitwise_shift_left(b6, 16)
    + int.bitwise_shift_left(b7, 24)
  case int.bitwise_and(inst, 0xE80) {
    0 ->
      riscv_decode_special_auipc(
        bytes_list,
        pos,
        inst,
        b4,
        b5,
        b6,
        b7,
        start_offset,
      )
    _ -> riscv_decode_pair(bytes_list, pos, inst, inst2_le)
  }
}

fn riscv_decode_pair(
  bytes_list: List(Int),
  pos: Int,
  inst: Int,
  inst2: Int,
) -> #(List(Int), Int) {
  use <- bool.guard(when: not_auipc_pair(inst, inst2), return: #(bytes_list, 6))
  riscv_decode_pair_apply(bytes_list, pos, inst, inst2)
}

fn riscv_decode_pair_apply(
  bytes_list: List(Int),
  pos: Int,
  inst: Int,
  inst2: Int,
) -> #(List(Int), Int) {
  let addr_base = int.bitwise_and(inst, 0xFFFFF000)
  let addr =
    int.bitwise_and(addr_base + int.bitwise_shift_right(inst2, 20), mask32)
  let new_inst =
    int.bitwise_or(
      0x17 + int.bitwise_shift_left(2, 7),
      int.bitwise_and(int.bitwise_shift_left(inst2, 12), mask32),
    )
  let new_inst2 = addr
  let bytes_inst = le32_bytes(new_inst)
  let bytes_inst2 = le32_bytes(new_inst2)
  let updated =
    list_replace_range(bytes_list, pos, list.append(bytes_inst, bytes_inst2))
  #(updated, 8)
}

fn riscv_decode_special_auipc(
  bytes_list: List(Int),
  pos: Int,
  inst: Int,
  b4: Int,
  b5: Int,
  b6: Int,
  b7: Int,
  start_offset: Int,
) -> #(List(Int), Int) {
  let inst2_rs1 = int.bitwise_shift_right(inst, 27)
  use <- bool.guard(when: not_special_auipc(inst, inst2_rs1), return: #(
    bytes_list,
    4,
  ))
  let addr_be =
    int.bitwise_shift_left(b4, 24)
    + int.bitwise_shift_left(b5, 16)
    + int.bitwise_shift_left(b6, 8)
    + b7
  let pc = start_offset + pos
  let addr = int.bitwise_and(addr_be - pc + 0x1_0000_0000, mask32)
  let new_inst2 =
    int.bitwise_or(
      int.bitwise_shift_right(inst, 12),
      int.bitwise_and(int.bitwise_shift_left(addr, 20), mask32),
    )
  let auipc_imm =
    int.bitwise_and(addr + 0x800, mask32)
    |> int.bitwise_and(0xFFFFF000)
  let new_inst =
    int.bitwise_or(
      int.bitwise_or(0x17, int.bitwise_shift_left(inst2_rs1, 7)),
      auipc_imm,
    )
  let bytes_inst = le32_bytes(new_inst)
  let bytes_inst2 = le32_bytes(new_inst2)
  let updated =
    list_replace_range(bytes_list, pos, list.append(bytes_inst, bytes_inst2))
  #(updated, 8)
}

fn not_auipc_pair(auipc: Int, inst2: Int) -> Bool {
  // Mirrors xz-utils NOT_AUIPC_PAIR macro:
  //   ((auipc << 8) ^ (inst2 - 3)) & 0xF8003
  let shifted = int.bitwise_and(int.bitwise_shift_left(auipc, 8), mask32)
  let diff = int.bitwise_and(inst2 - 3 + 0x1_0000_0000, mask32)
  int.bitwise_and(int.bitwise_exclusive_or(shifted, diff), 0xF8003) != 0
}

fn not_special_auipc(auipc: Int, inst2_rs1: Int) -> Bool {
  // Mirrors NOT_SPECIAL_AUIPC: (uint32_t)(((auipc) - 0x3117) << 18)
  // >= (rs1 & 0x1D).  The (uint32_t) cast truncates to 32 bits.
  let diff = int.bitwise_and(auipc - 0x3117 + 0x1_0000_0000, mask32)
  let lhs = int.bitwise_and(int.bitwise_shift_left(diff, 18), mask32)
  let rhs = int.bitwise_and(inst2_rs1, 0x1D)
  lhs >= rhs
}

fn le32_bytes(value: Int) -> List(Int) {
  let masked = int.bitwise_and(value, mask32)
  [
    int.bitwise_and(masked, 0xFF),
    int.bitwise_and(int.bitwise_shift_right(masked, 8), 0xFF),
    int.bitwise_and(int.bitwise_shift_right(masked, 16), 0xFF),
    int.bitwise_and(int.bitwise_shift_right(masked, 24), 0xFF),
  ]
}
