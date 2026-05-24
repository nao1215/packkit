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
//// (`src/liblzma/simple/{x86,arm,arm64,armthumb,powerpc,sparc}.c`,
//// 0BSD licensed).  Implementations are written from the algorithm
//// description, not copied; the reference is consulted to confirm
//// edge cases such as the x86 `prev_mask` state machine.

import gleam/bit_array
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
