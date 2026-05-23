//// Pure Gleam LZMA decoder used by the `xz` (LZMA2) and `seven_z`
//// codecs.  The implementation follows Igor Pavlov's reference
//// decoder: range coder + 12-state machine + sliding dictionary.
////
//// Probabilities are stored in a `dict.Dict(Int, Int)` keyed by a
//// stable encoding of (table, sub-index).  This is slower than the
//// canonical flat array but works on both Erlang and JavaScript
//// targets without FFI and is correct for the comparatively small
//// LZMA fragments that appear inside an `.xz` block or a `.7z`
//// folder.

import gleam/bool
import gleam/dict
import gleam/int
import gleam/result
import packkit/error

const num_bit_model_total_bits: Int = 11

const bit_model_total: Int = 2048

const num_move_bits: Int = 5

const top_value: Int = 16_777_216

const bit_model_init: Int = 1024

const num_pos_bits_max: Int = 4

const num_pos_states_max: Int = 16

const num_low_len_bits: Int = 3

const num_mid_len_bits: Int = 3

const num_high_len_bits: Int = 8

const num_low_len: Int = 8

const num_mid_len: Int = 8

const num_align_bits: Int = 4

const start_pos_model_index: Int = 4

const end_pos_model_index: Int = 14

const num_len_to_pos_states: Int = 4

const match_min_len: Int = 2

// Probability table identifiers.  The encoder packs (table_id, index)
// into a single Int via table_id * 65_536 + index, which gives every
// LZMA probability a unique dictionary key.
const t_is_match: Int = 0

const t_is_rep: Int = 1

const t_is_rep_g0: Int = 2

const t_is_rep_g1: Int = 3

const t_is_rep_g2: Int = 4

const t_is_rep0_long: Int = 5

const t_literal: Int = 6

const t_pos_slot: Int = 7

const t_pos_dec: Int = 8

const t_align: Int = 9

const t_len_choice: Int = 10

const t_len_choice2: Int = 11

const t_len_low: Int = 12

const t_len_mid: Int = 13

const t_len_high: Int = 14

const t_rep_len_choice: Int = 15

const t_rep_len_choice2: Int = 16

const t_rep_len_low: Int = 17

const t_rep_len_mid: Int = 18

const t_rep_len_high: Int = 19

// -- public types --------------------------------------------------------

/// LZMA properties: literal context bits (`lc`), literal position
/// bits (`lp`), and position bits (`pb`).
pub type Properties {
  Properties(lc: Int, lp: Int, pb: Int)
}

/// Decode an LZMA properties byte into typed properties.
pub fn properties_of_byte(byte: Int) -> Result(Properties, error.CodecError) {
  use <- bool.guard(
    when: byte > 224,
    return: Error(error.CodecInvalidData(
      message: "invalid LZMA properties byte",
    )),
  )
  let pb = byte / 45
  let remainder = byte - pb * 45
  let lp = remainder / 9
  let lc = remainder - lp * 9
  use <- bool.guard(
    when: lc + lp > 4,
    return: Error(error.CodecInvalidData(message: "LZMA lc + lp must be <= 4")),
  )
  use <- bool.guard(
    when: pb > num_pos_bits_max,
    return: Error(error.CodecInvalidData(message: "LZMA pb out of range")),
  )
  Ok(Properties(lc: lc, lp: lp, pb: pb))
}

/// Mutable-style decoder state (returned by every operation as the
/// new value).
pub opaque type Decoder {
  Decoder(
    range: Int,
    code: Int,
    input: BitArray,
    output_rev: List(Int),
    output_len: Int,
    output_limit: Int,
    state: Int,
    rep0: Int,
    rep1: Int,
    rep2: Int,
    rep3: Int,
    props: Properties,
    probs: dict.Dict(Int, Int),
  )
}

/// Build a fresh decoder seeded with the LZMA range coder initial
/// state from `input`.  The caller supplies the expected uncompressed
/// length to drive the main loop and an optional safety cap.
pub fn new(
  input: BitArray,
  props: Properties,
  output_limit: Int,
) -> Result(Decoder, error.CodecError) {
  case input {
    <<first, rest:bytes>> -> {
      use <- bool.guard(
        when: first != 0,
        return: Error(error.CodecInvalidData(
          message: "LZMA range coder must start with a zero byte",
        )),
      )
      use #(code, rest) <- result.try(read_u32_be(rest))
      Ok(Decoder(
        range: 0xFFFFFFFF,
        code: code,
        input: rest,
        output_rev: [],
        output_len: 0,
        output_limit: output_limit,
        state: 0,
        rep0: 0,
        rep1: 0,
        rep2: 0,
        rep3: 0,
        props: props,
        probs: dict.new(),
      ))
    }
    _ ->
      Error(error.CodecInvalidData(
        message: "LZMA range coder needs at least 5 priming bytes",
      ))
  }
}

/// Drive the decoder until `desired_output` bytes have been emitted
/// or an end-of-stream marker fires.  Returns the produced bytes plus
/// the remaining decoder state.
pub fn decode_into(
  decoder: Decoder,
  desired_output: Int,
) -> Result(#(BitArray, Decoder), error.CodecError) {
  use decoder <- result.try(loop_until(decoder, desired_output))
  let bytes = list_reverse_to_bit_array(decoder.output_rev, <<>>)
  Ok(#(bytes, decoder))
}

// -- main decode loop ---------------------------------------------------

fn loop_until(
  decoder: Decoder,
  desired_output: Int,
) -> Result(Decoder, error.CodecError) {
  case decoder.output_len >= desired_output {
    True -> Ok(decoder)
    False -> {
      let pos_state =
        int.bitwise_and(decoder.output_len, mask_for(decoder.props.pb))
      use #(bit, decoder) <- result.try(decode_bit(
        decoder,
        prob_key(t_is_match, decoder.state * num_pos_states_max + pos_state),
      ))
      case bit {
        0 -> {
          use decoder <- result.try(decode_literal(decoder))
          loop_until(decoder, desired_output)
        }
        _ -> {
          use #(is_rep_bit, decoder) <- result.try(decode_bit(
            decoder,
            prob_key(t_is_rep, decoder.state),
          ))
          case is_rep_bit {
            0 -> {
              use decoder <- result.try(decode_match(decoder, pos_state))
              loop_until(decoder, desired_output)
            }
            _ -> {
              use decoder <- result.try(decode_rep(decoder, pos_state))
              loop_until(decoder, desired_output)
            }
          }
        }
      }
    }
  }
}

// -- literal ------------------------------------------------------------

fn decode_literal(decoder: Decoder) -> Result(Decoder, error.CodecError) {
  let prev_byte = previous_output_byte(decoder)
  let lit_pos_state =
    int.bitwise_and(decoder.output_len, mask_for(decoder.props.lp))
  let lit_high = int.bitwise_shift_right(prev_byte, 8 - decoder.props.lc)
  let context_index =
    int.bitwise_or(
      int.bitwise_shift_left(lit_pos_state, decoder.props.lc),
      lit_high,
    )
  let prob_base = context_index * 0x300
  case decoder.state < 7 {
    True -> decode_literal_normal(decoder, prob_base, 1)
    False -> decode_literal_matched(decoder, prob_base, 1, match_byte(decoder))
  }
}

fn decode_literal_normal(
  decoder: Decoder,
  base: Int,
  symbol: Int,
) -> Result(Decoder, error.CodecError) {
  case symbol >= 0x100 {
    True -> {
      let byte = int.bitwise_and(symbol, 0xFF)
      let decoder = emit_byte(decoder, byte)
      Ok(advance_state_literal(decoder))
    }
    False -> {
      use #(bit, decoder) <- result.try(decode_bit(
        decoder,
        prob_key(t_literal, base + symbol),
      ))
      decode_literal_normal(decoder, base, { symbol * 2 } + bit)
    }
  }
}

fn decode_literal_matched(
  decoder: Decoder,
  base: Int,
  symbol: Int,
  match_b: Int,
) -> Result(Decoder, error.CodecError) {
  case symbol >= 0x100 {
    True -> {
      let byte = int.bitwise_and(symbol, 0xFF)
      let decoder = emit_byte(decoder, byte)
      Ok(advance_state_literal(decoder))
    }
    False -> {
      let match_bit = int.bitwise_and(int.bitwise_shift_right(match_b, 7), 0x01)
      let next_match = int.bitwise_and(match_b * 2, 0xFF)
      let prob_offset = 0x100 + match_bit * 0x100 + symbol
      use #(bit, decoder) <- result.try(decode_bit(
        decoder,
        prob_key(t_literal, base + prob_offset),
      ))
      case bit == match_bit {
        True ->
          decode_literal_matched(
            decoder,
            base,
            { symbol * 2 } + bit,
            next_match,
          )
        False -> decode_literal_normal(decoder, base, { symbol * 2 } + bit)
      }
    }
  }
}

fn previous_output_byte(decoder: Decoder) -> Int {
  case decoder.output_rev {
    [head, ..] -> head
    [] -> 0
  }
}

fn match_byte(decoder: Decoder) -> Int {
  byte_at_distance(decoder, decoder.rep0 + 1)
}

fn byte_at_distance(decoder: Decoder, distance: Int) -> Int {
  case distance <= 0 {
    True -> 0
    False ->
      case nth_back(decoder.output_rev, distance - 1) {
        Ok(value) -> value
        Error(_) -> 0
      }
  }
}

fn nth_back(values: List(Int), n: Int) -> Result(Int, Nil) {
  case values, n {
    [head, ..], 0 -> Ok(head)
    [_, ..rest], _ -> nth_back(rest, n - 1)
    [], _ -> Error(Nil)
  }
}

fn advance_state_literal(decoder: Decoder) -> Decoder {
  let new_state = case decoder.state {
    0 -> 0
    1 -> 0
    2 -> 0
    3 -> 0
    4 -> 1
    5 -> 2
    6 -> 3
    7 -> 4
    8 -> 5
    9 -> 6
    10 -> 4
    _ -> 5
  }
  Decoder(..decoder, state: new_state)
}

// -- match --------------------------------------------------------------

fn decode_match(
  decoder: Decoder,
  pos_state: Int,
) -> Result(Decoder, error.CodecError) {
  let _ = pos_state
  let decoder =
    Decoder(
      ..decoder,
      rep3: decoder.rep2,
      rep2: decoder.rep1,
      rep1: decoder.rep0,
    )
  use #(length, decoder) <- result.try(decode_length(
    decoder,
    pos_state,
    t_len_choice,
    t_len_choice2,
    t_len_low,
    t_len_mid,
    t_len_high,
  ))
  use #(distance, decoder) <- result.try(decode_distance(decoder, length))
  let decoder =
    Decoder(..decoder, rep0: distance, state: match_next(decoder.state))
  apply_copy(decoder, length)
}

fn match_next(state: Int) -> Int {
  case state < 7 {
    True -> 7
    False -> 10
  }
}

// -- repeats ------------------------------------------------------------

fn decode_rep(
  decoder: Decoder,
  pos_state: Int,
) -> Result(Decoder, error.CodecError) {
  use #(g0, decoder) <- result.try(decode_bit(
    decoder,
    prob_key(t_is_rep_g0, decoder.state),
  ))
  case g0 {
    0 -> {
      use #(g0_long, decoder) <- result.try(decode_bit(
        decoder,
        prob_key(t_is_rep0_long, decoder.state * num_pos_states_max + pos_state),
      ))
      case g0_long {
        0 -> {
          let decoder = Decoder(..decoder, state: short_rep_next(decoder.state))
          apply_copy(decoder, 1)
        }
        _ -> apply_rep_match(decoder, decoder.rep0, pos_state)
      }
    }
    _ -> {
      use #(g1, decoder) <- result.try(decode_bit(
        decoder,
        prob_key(t_is_rep_g1, decoder.state),
      ))
      case g1 {
        0 -> apply_rep_match(decoder, decoder.rep1, pos_state)
        _ -> {
          use #(g2, decoder) <- result.try(decode_bit(
            decoder,
            prob_key(t_is_rep_g2, decoder.state),
          ))
          case g2 {
            0 -> apply_rep_match(decoder, decoder.rep2, pos_state)
            _ -> apply_rep_match(decoder, decoder.rep3, pos_state)
          }
        }
      }
    }
  }
}

fn apply_rep_match(
  decoder: Decoder,
  selected: Int,
  pos_state: Int,
) -> Result(Decoder, error.CodecError) {
  let #(rep1, rep2, rep3) = case True {
    _ if selected == decoder.rep0 -> #(decoder.rep1, decoder.rep2, decoder.rep3)
    _ if selected == decoder.rep1 -> #(decoder.rep0, decoder.rep2, decoder.rep3)
    _ if selected == decoder.rep2 -> #(decoder.rep0, decoder.rep1, decoder.rep3)
    _ -> #(decoder.rep0, decoder.rep1, decoder.rep2)
  }
  let decoder =
    Decoder(
      ..decoder,
      rep0: selected,
      rep1: rep1,
      rep2: rep2,
      rep3: rep3,
      state: rep_next(decoder.state),
    )
  use #(length, decoder) <- result.try(decode_length(
    decoder,
    pos_state,
    t_rep_len_choice,
    t_rep_len_choice2,
    t_rep_len_low,
    t_rep_len_mid,
    t_rep_len_high,
  ))
  apply_copy(decoder, length)
}

fn short_rep_next(state: Int) -> Int {
  case state < 7 {
    True -> 9
    False -> 11
  }
}

fn rep_next(state: Int) -> Int {
  case state < 7 {
    True -> 8
    False -> 11
  }
}

fn apply_copy(
  decoder: Decoder,
  length: Int,
) -> Result(Decoder, error.CodecError) {
  copy_loop(decoder, decoder.rep0, length)
}

fn copy_loop(
  decoder: Decoder,
  distance: Int,
  remaining: Int,
) -> Result(Decoder, error.CodecError) {
  case remaining {
    0 -> Ok(decoder)
    _ -> {
      use <- bool.guard(
        when: distance >= decoder.output_len
          && decoder.output_len < decoder.output_limit,
        return: Error(error.CodecInvalidData(
          message: "LZMA back-reference exceeds dictionary",
        )),
      )
      let byte = byte_at_distance(decoder, distance + 1)
      let decoder = emit_byte(decoder, byte)
      copy_loop(decoder, distance, remaining - 1)
    }
  }
}

// -- length decoder -----------------------------------------------------

fn decode_length(
  decoder: Decoder,
  pos_state: Int,
  t_choice: Int,
  t_choice2: Int,
  t_low: Int,
  t_mid: Int,
  t_high: Int,
) -> Result(#(Int, Decoder), error.CodecError) {
  use #(choice, decoder) <- result.try(decode_bit(
    decoder,
    prob_key(t_choice, 0),
  ))
  case choice {
    0 -> {
      use #(value, decoder) <- result.try(decode_bit_tree(
        decoder,
        t_low,
        pos_state * num_low_len,
        num_low_len_bits,
      ))
      Ok(#(match_min_len + value, decoder))
    }
    _ -> {
      use #(choice2, decoder) <- result.try(decode_bit(
        decoder,
        prob_key(t_choice2, 0),
      ))
      case choice2 {
        0 -> {
          use #(value, decoder) <- result.try(decode_bit_tree(
            decoder,
            t_mid,
            pos_state * num_mid_len,
            num_mid_len_bits,
          ))
          Ok(#(match_min_len + num_low_len + value, decoder))
        }
        _ -> {
          use #(value, decoder) <- result.try(decode_bit_tree(
            decoder,
            t_high,
            0,
            num_high_len_bits,
          ))
          Ok(#(match_min_len + num_low_len + num_mid_len + value, decoder))
        }
      }
    }
  }
}

// -- distance decoder --------------------------------------------------

fn decode_distance(
  decoder: Decoder,
  length: Int,
) -> Result(#(Int, Decoder), error.CodecError) {
  let len_state = case length - match_min_len < num_len_to_pos_states {
    True -> length - match_min_len
    False -> num_len_to_pos_states - 1
  }
  use #(pos_slot, decoder) <- result.try(decode_bit_tree(
    decoder,
    t_pos_slot,
    len_state * 64,
    6,
  ))
  case pos_slot < start_pos_model_index {
    True -> Ok(#(pos_slot, decoder))
    False -> {
      let num_direct_bits = int.bitwise_shift_right(pos_slot, 1) - 1
      let base =
        int.bitwise_shift_left(
          int.bitwise_or(2, int.bitwise_and(pos_slot, 1)),
          num_direct_bits,
        )
      case pos_slot < end_pos_model_index {
        True -> {
          let offset = base - pos_slot
          use #(extra, decoder) <- result.try(decode_reverse_bit_tree(
            decoder,
            t_pos_dec,
            offset,
            num_direct_bits,
          ))
          Ok(#(base + extra, decoder))
        }
        False -> {
          let high_bits = num_direct_bits - num_align_bits
          use #(top, decoder) <- result.try(decode_direct_bits(
            decoder,
            high_bits,
          ))
          let middle = int.bitwise_shift_left(top, num_align_bits)
          use #(align_bits, decoder) <- result.try(decode_reverse_bit_tree(
            decoder,
            t_align,
            0,
            num_align_bits,
          ))
          Ok(#(base + middle + align_bits, decoder))
        }
      }
    }
  }
}

// -- range decoder primitives -------------------------------------------

fn decode_bit(
  decoder: Decoder,
  key: Int,
) -> Result(#(Int, Decoder), error.CodecError) {
  let prob = case dict.get(decoder.probs, key) {
    Ok(value) -> value
    Error(_) -> bit_model_init
  }
  let bound =
    int.bitwise_shift_right(decoder.range, num_bit_model_total_bits) * prob
  case decoder.code < bound {
    True -> {
      let new_prob =
        prob + int.bitwise_shift_right(bit_model_total - prob, num_move_bits)
      let decoder =
        Decoder(
          ..decoder,
          range: bound,
          probs: dict.insert(decoder.probs, key, new_prob),
        )
      use decoder <- result.try(normalize(decoder))
      Ok(#(0, decoder))
    }
    False -> {
      let new_prob = prob - int.bitwise_shift_right(prob, num_move_bits)
      let decoder =
        Decoder(
          ..decoder,
          range: decoder.range - bound,
          code: decoder.code - bound,
          probs: dict.insert(decoder.probs, key, new_prob),
        )
      use decoder <- result.try(normalize(decoder))
      Ok(#(1, decoder))
    }
  }
}

fn decode_direct_bits(
  decoder: Decoder,
  count: Int,
) -> Result(#(Int, Decoder), error.CodecError) {
  decode_direct_bits_loop(decoder, count, 0)
}

fn decode_direct_bits_loop(
  decoder: Decoder,
  remaining: Int,
  acc: Int,
) -> Result(#(Int, Decoder), error.CodecError) {
  case remaining {
    0 -> Ok(#(acc, decoder))
    _ -> {
      let new_range = int.bitwise_shift_right(decoder.range, 1)
      case decoder.code >= new_range {
        True -> {
          let decoder =
            Decoder(..decoder, range: new_range, code: decoder.code - new_range)
          use decoder <- result.try(normalize(decoder))
          decode_direct_bits_loop(decoder, remaining - 1, acc * 2 + 1)
        }
        False -> {
          let decoder = Decoder(..decoder, range: new_range)
          use decoder <- result.try(normalize(decoder))
          decode_direct_bits_loop(decoder, remaining - 1, acc * 2)
        }
      }
    }
  }
}

fn decode_bit_tree(
  decoder: Decoder,
  table: Int,
  base: Int,
  num_bits: Int,
) -> Result(#(Int, Decoder), error.CodecError) {
  decode_bit_tree_loop(decoder, table, base, num_bits, 1, num_bits)
}

fn decode_bit_tree_loop(
  decoder: Decoder,
  table: Int,
  base: Int,
  remaining: Int,
  symbol: Int,
  total_bits: Int,
) -> Result(#(Int, Decoder), error.CodecError) {
  case remaining {
    0 -> Ok(#(symbol - int.bitwise_shift_left(1, total_bits), decoder))
    _ -> {
      use #(bit, decoder) <- result.try(decode_bit(
        decoder,
        prob_key(table, base + symbol),
      ))
      decode_bit_tree_loop(
        decoder,
        table,
        base,
        remaining - 1,
        symbol * 2 + bit,
        total_bits,
      )
    }
  }
}

fn decode_reverse_bit_tree(
  decoder: Decoder,
  table: Int,
  base: Int,
  num_bits: Int,
) -> Result(#(Int, Decoder), error.CodecError) {
  decode_reverse_bit_tree_loop(decoder, table, base, num_bits, 1, 0, 0)
}

fn decode_reverse_bit_tree_loop(
  decoder: Decoder,
  table: Int,
  base: Int,
  remaining: Int,
  symbol: Int,
  result_acc: Int,
  bit_index: Int,
) -> Result(#(Int, Decoder), error.CodecError) {
  case remaining {
    0 -> Ok(#(result_acc, decoder))
    _ -> {
      use #(bit, decoder) <- result.try(decode_bit(
        decoder,
        prob_key(table, base + symbol),
      ))
      decode_reverse_bit_tree_loop(
        decoder,
        table,
        base,
        remaining - 1,
        symbol * 2 + bit,
        result_acc + int.bitwise_shift_left(bit, bit_index),
        bit_index + 1,
      )
    }
  }
}

fn normalize(decoder: Decoder) -> Result(Decoder, error.CodecError) {
  case decoder.range < top_value {
    False -> Ok(decoder)
    True ->
      case decoder.input {
        <<byte, rest:bytes>> ->
          Ok(
            Decoder(
              ..decoder,
              range: int.bitwise_and(decoder.range * 256, 0xFFFFFFFF),
              code: int.bitwise_and(decoder.code * 256 + byte, 0xFFFFFFFF),
              input: rest,
            ),
          )
        _ ->
          Error(error.CodecInvalidData(
            message: "LZMA range coder ran out of input bytes",
          ))
      }
  }
}

// -- emit / helpers ----------------------------------------------------

fn emit_byte(decoder: Decoder, byte: Int) -> Decoder {
  Decoder(
    ..decoder,
    output_rev: [byte, ..decoder.output_rev],
    output_len: decoder.output_len + 1,
  )
}

fn prob_key(table: Int, sub_index: Int) -> Int {
  table * 65_536 + sub_index
}

fn mask_for(bits: Int) -> Int {
  int.bitwise_shift_left(1, bits) - 1
}

fn read_u32_be(bytes: BitArray) -> Result(#(Int, BitArray), error.CodecError) {
  case bytes {
    <<value:big-unsigned-size(32), rest:bytes>> -> Ok(#(value, rest))
    _ ->
      Error(error.CodecInvalidData(
        message: "LZMA range coder priming requires 4 bytes",
      ))
  }
}

fn list_reverse_to_bit_array(values: List(Int), acc: BitArray) -> BitArray {
  case values {
    [] -> acc
    [head, ..rest] -> list_reverse_to_bit_array(rest, <<head, acc:bits>>)
  }
}
