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

import gleam/bit_array
import gleam/bool
import gleam/dict
import gleam/int
import gleam/option.{type Option, None, Some}
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

// `loop_until` runs once per emitted byte, so its recursive tail call
// must compile to a real while loop on every target.  The `use` /
// `result.try` sugar would compile to JS callbacks (the recursive
// call ends up inside the callback's body, not at the function's tail
// position) and accumulate a stack frame per iteration — JS engines
// blow the stack at ~10000 frames, which limits any single LZMA chunk
// to a few KiB on the JavaScript target.  Spelling the case branches
// out manually keeps every `loop_until` call literally in tail
// position so Gleam emits a while loop and we can decode 32 KiB
// chunks without exhausting the stack.
fn loop_until(
  decoder: Decoder,
  desired_output: Int,
) -> Result(Decoder, error.CodecError) {
  case decoder.output_len >= desired_output {
    True -> Ok(decoder)
    False -> {
      let pos_state =
        int.bitwise_and(decoder.output_len, mask_for(decoder.props.pb))
      case
        decode_bit(
          decoder,
          prob_key(t_is_match, decoder.state * num_pos_states_max + pos_state),
        )
      {
        Error(e) -> Error(e)
        Ok(#(0, decoder)) ->
          case decode_literal(decoder) {
            Error(e) -> Error(e)
            Ok(decoder) -> loop_until(decoder, desired_output)
          }
        Ok(#(_, decoder)) ->
          case decode_bit(decoder, prob_key(t_is_rep, decoder.state)) {
            Error(e) -> Error(e)
            Ok(#(0, decoder)) ->
              case decode_match(decoder, pos_state) {
                Error(e) -> Error(e)
                Ok(decoder) -> loop_until(decoder, desired_output)
              }
            Ok(#(_, decoder)) ->
              case decode_rep(decoder, pos_state) {
                Error(e) -> Error(e)
                Ok(decoder) -> loop_until(decoder, desired_output)
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

// -- LZMA1 literal-only encoder ----------------------------------------
//
// The encoder is a mirror of the decoder's range coder and literal
// path: every input byte is emitted as an LZMA literal (no LZ77 match
// search), which produces a stream that any conforming LZMA1 decoder
// accepts.  The compression ratio is roughly 1.125x (8 bits of literal
// + 1 is_match bit per input byte before adaptive probability
// updates kick in), but the encoder is small enough to be obviously
// correct and unblocks the ZIP method-14 and 7z encoders that wrap an
// LZMA1 byte stream.  A future revision can plug in a hash-chain
// match finder without changing this surface.

const range_init: Int = 0xFFFFFFFF

const u32_bound: Int = 4_294_967_296

const low_carry_threshold: Int = 0xFF000000

// Output the LZMA properties byte that the wrapper of a raw stream
// (LZMA1, lzip, PKWARE LZMA, 7z, ...) must put in its property field.
pub fn properties_to_byte(props: Properties) -> Int {
  props.pb * 45 + props.lp * 9 + props.lc
}

/// Encode `bytes` as an LZMA1 range-coded payload that emits every
/// input byte as a literal.  The output is the raw range-coded stream
/// (no LZMA `.lzma`/`.xz`/PKWARE header), suitable to drop into any
/// wrapper that carries the LZMA properties and uncompressed size out
/// of band.  Decoding via `new` + `decode_into(_, byte_size(bytes))`
/// returns the original payload.
pub fn encode_literal_only(
  bytes bytes: BitArray,
  props props: Properties,
) -> BitArray {
  let encoder = new_encoder(props)
  let encoder = encode_literal_only_loop(encoder, bytes)
  let encoder = finish_encoder(encoder)
  list_reverse_to_bit_array(encoder.out_bytes_rev, <<>>)
}

type Encoder {
  Encoder(
    range: Int,
    low: Int,
    cache: Int,
    cache_size: Int,
    state: Int,
    rep0: Int,
    rep1: Int,
    rep2: Int,
    rep3: Int,
    props: Properties,
    probs: dict.Dict(Int, Int),
    output_rev: List(Int),
    output_len: Int,
    out_bytes_rev: List(Int),
  )
}

fn new_encoder(props: Properties) -> Encoder {
  Encoder(
    range: range_init,
    low: 0,
    cache: 0,
    cache_size: 1,
    state: 0,
    rep0: 0,
    rep1: 0,
    rep2: 0,
    rep3: 0,
    props: props,
    probs: dict.new(),
    output_rev: [],
    output_len: 0,
    out_bytes_rev: [],
  )
}

fn encode_literal_only_loop(encoder: Encoder, input: BitArray) -> Encoder {
  case input {
    <<byte, rest:bytes>> -> {
      let pos_state =
        int.bitwise_and(encoder.output_len, mask_for(encoder.props.pb))
      // is_match bit = 0 (we never emit a match in this mode).
      let encoder =
        encode_bit(
          encoder,
          prob_key(t_is_match, encoder.state * num_pos_states_max + pos_state),
          0,
        )
      let encoder = encode_literal_byte(encoder, byte)
      let encoder =
        Encoder(
          ..encoder,
          output_rev: [byte, ..encoder.output_rev],
          output_len: encoder.output_len + 1,
        )
      encode_literal_only_loop(encoder, rest)
    }
    _ -> encoder
  }
}

fn encode_literal_byte(encoder: Encoder, byte: Int) -> Encoder {
  let prev_byte = case encoder.output_rev {
    [head, ..] -> head
    [] -> 0
  }
  let lit_pos_state =
    int.bitwise_and(encoder.output_len, mask_for(encoder.props.lp))
  let lit_high = int.bitwise_shift_right(prev_byte, 8 - encoder.props.lc)
  let context_index =
    int.bitwise_or(
      int.bitwise_shift_left(lit_pos_state, encoder.props.lc),
      lit_high,
    )
  let prob_base = context_index * 0x300
  // state < 7 always (we never emit matches), so the decoder uses the
  // unmatched literal path — emit 8 bits MSB-first.
  let encoder = encode_literal_bits(encoder, prob_base, 1, byte, 8)
  Encoder(..encoder, state: literal_state_after(encoder.state))
}

fn encode_literal_bits(
  encoder: Encoder,
  base: Int,
  symbol: Int,
  byte: Int,
  remaining: Int,
) -> Encoder {
  case remaining {
    0 -> encoder
    _ -> {
      let bit_pos = remaining - 1
      let bit = int.bitwise_and(int.bitwise_shift_right(byte, bit_pos), 1)
      let encoder = encode_bit(encoder, prob_key(t_literal, base + symbol), bit)
      encode_literal_bits(encoder, base, symbol * 2 + bit, byte, remaining - 1)
    }
  }
}

fn literal_state_after(state: Int) -> Int {
  case state {
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
}

fn encode_bit(encoder: Encoder, key: Int, bit: Int) -> Encoder {
  let prob = case dict.get(encoder.probs, key) {
    Ok(value) -> value
    Error(_) -> bit_model_init
  }
  let new_bound =
    int.bitwise_shift_right(encoder.range, num_bit_model_total_bits) * prob
  let encoder = case bit {
    0 -> {
      let new_prob =
        prob + int.bitwise_shift_right(bit_model_total - prob, num_move_bits)
      Encoder(
        ..encoder,
        range: new_bound,
        probs: dict.insert(encoder.probs, key, new_prob),
      )
    }
    _ -> {
      let new_prob = prob - int.bitwise_shift_right(prob, num_move_bits)
      Encoder(
        ..encoder,
        low: encoder.low + new_bound,
        range: encoder.range - new_bound,
        probs: dict.insert(encoder.probs, key, new_prob),
      )
    }
  }
  normalize_encoder(encoder)
}

fn normalize_encoder(encoder: Encoder) -> Encoder {
  case encoder.range < top_value {
    False -> encoder
    True -> {
      // range < 2^24 ⇒ range * 256 < 2^32, safe on the JS Number
      // 53-bit ceiling.  shift_low first because the C reference also
      // emits the cached byte before re-doubling the range; order
      // within a single normalize step does not affect correctness
      // since shift_low does not read `range`.
      let encoder = shift_low_encoder(encoder)
      let encoder = Encoder(..encoder, range: encoder.range * 256)
      normalize_encoder(encoder)
    }
  }
}

fn shift_low_encoder(encoder: Encoder) -> Encoder {
  // The LZMA SDK trick: when `low` is in the dangerous band
  // [0xFF000000, 0xFFFFFFFF] we DEFER output (cached bytes might still
  // get a +1 carry from a future encode_bit).  Outside that band the
  // cache is stable (no future carry can change it) so we flush every
  // deferred byte at once, adding the carry that just propagated to
  // bit 32 — `(low >> 32)` is 0 or 1.
  case encoder.low < low_carry_threshold || encoder.low > 0xFFFFFFFF {
    True -> {
      let carry = encoder.low / u32_bound
      let flushed =
        flush_cache_bytes(
          encoder.cache,
          encoder.cache_size,
          carry,
          encoder.out_bytes_rev,
        )
      let new_cache = int.bitwise_and(encoder.low / 16_777_216, 0xFF)
      let new_low = shift_low_left_byte(encoder.low)
      Encoder(
        ..encoder,
        out_bytes_rev: flushed,
        cache: new_cache,
        cache_size: 1,
        low: new_low,
      )
    }
    False -> {
      let new_low = shift_low_left_byte(encoder.low)
      Encoder(..encoder, cache_size: encoder.cache_size + 1, low: new_low)
    }
  }
}

fn shift_low_left_byte(low: Int) -> Int {
  // Equivalent to `(uint32_t)low << 8` in C: mask to 32 bits FIRST
  // (the carry / top byte have already been moved into the cache by
  // the caller), then shift, then mask the result to 32 bits again so
  // the new register starts in [0, 2^32).  Doing arithmetically
  // because `int.bitwise_*` on the JS target collapses to 32-bit
  // signed semantics, which would corrupt 33-bit intermediate values.
  let truncated = case low >= u32_bound {
    True -> low - u32_bound * { low / u32_bound }
    False -> low
  }
  let raw = truncated * 256
  case raw >= u32_bound {
    True -> raw - u32_bound * { raw / u32_bound }
    False -> raw
  }
}

fn flush_cache_bytes(
  cache_byte: Int,
  cache_size: Int,
  carry: Int,
  out_rev: List(Int),
) -> List(Int) {
  case cache_size {
    0 -> out_rev
    _ -> {
      let byte = int.bitwise_and(cache_byte + carry, 0xFF)
      flush_cache_bytes(0xFF, cache_size - 1, carry, [byte, ..out_rev])
    }
  }
}

fn finish_encoder(encoder: Encoder) -> Encoder {
  // Five shift_low cycles flush the remaining 40 bits of range coder
  // state.  After the final cycle every cached byte has been emitted
  // (or will be on the next shift) and the decoder's range coder can
  // satisfy its `normalize` step from the trailing bytes.
  encoder
  |> shift_low_encoder
  |> shift_low_encoder
  |> shift_low_encoder
  |> shift_low_encoder
  |> shift_low_encoder
}

// -- LZMA1 encoder with LZ77 match finding ------------------------------
//
// `encode_with_lz77` reuses the range coder + literal path of the
// literal-only encoder but additionally runs a 3-byte hash chain over
// the input and emits LZMA matches whenever it can find a back-
// reference of three or more bytes within the previous 32 KiB.  No rep
// matches yet — every match is a fresh distance encoded through the
// pos-slot scheme — but matches alone already cut text payloads down
// to under half of the literal-only baseline.

const lzma_lz77_min_match: Int = 3

const lzma_lz77_max_distance: Int = 0x8000

const lzma_lz77_max_match: Int = 273

/// Encode `bytes` as a raw LZMA1 range-coded stream with LZ77 match
/// finding.  Compatible with the same `lzma.new` + `lzma.decode_into`
/// decoder used by `encode_literal_only`; the only difference is the
/// presence of matches in the bitstream, which is a strict superset
/// of literal-only output.
pub fn encode_with_lz77(
  bytes bytes: BitArray,
  props props: Properties,
) -> BitArray {
  let size = bit_array.byte_size(bytes)
  let encoder = new_encoder(props)
  let encoder = lz77_main_loop(bytes, 0, size, encoder, dict.new())
  let encoder = finish_encoder(encoder)
  list_reverse_to_bit_array(encoder.out_bytes_rev, <<>>)
}

fn lz77_main_loop(
  bytes: BitArray,
  pos: Int,
  size: Int,
  encoder: Encoder,
  hashes: dict.Dict(Int, Int),
) -> Encoder {
  case pos >= size {
    True -> encoder
    False ->
      case pos + lzma_lz77_min_match > size {
        // Too few bytes left for a 3-byte hash — emit remaining as
        // literals.
        True -> {
          let byte = byte_at_input(bytes, pos)
          let encoder = emit_lzma_literal(encoder, bytes, pos, byte)
          lz77_main_loop(bytes, pos + 1, size, encoder, hashes)
        }
        False -> {
          let b0 = byte_at_input(bytes, pos)
          let b1 = byte_at_input(bytes, pos + 1)
          let b2 = byte_at_input(bytes, pos + 2)
          let key = lzma_hash3(b0, b1, b2)
          case dict.get(hashes, key) {
            Error(_) -> {
              let encoder = emit_lzma_literal(encoder, bytes, pos, b0)
              let hashes = dict.insert(hashes, key, pos)
              lz77_main_loop(bytes, pos + 1, size, encoder, hashes)
            }
            Ok(prev) -> {
              let distance = pos - prev
              case distance <= 0 || distance > lzma_lz77_max_distance {
                True -> {
                  let encoder = emit_lzma_literal(encoder, bytes, pos, b0)
                  let hashes = dict.insert(hashes, key, pos)
                  lz77_main_loop(bytes, pos + 1, size, encoder, hashes)
                }
                False -> {
                  let cap = case size - pos < lzma_lz77_max_match {
                    True -> size - pos
                    False -> lzma_lz77_max_match
                  }
                  let m_len = lzma_match_length(bytes, prev, pos, cap, 0)
                  case m_len >= lzma_lz77_min_match {
                    True -> {
                      let pos_state =
                        int.bitwise_and(pos, mask_for(encoder.props.pb))
                      let encoder =
                        emit_lzma_match(encoder, pos_state, m_len, distance - 1)
                      let hashes =
                        update_hashes_in_range(
                          bytes,
                          dict.insert(hashes, key, pos),
                          pos + 1,
                          pos + m_len,
                          size,
                        )
                      lz77_main_loop(bytes, pos + m_len, size, encoder, hashes)
                    }
                    False -> {
                      let encoder = emit_lzma_literal(encoder, bytes, pos, b0)
                      let hashes = dict.insert(hashes, key, pos)
                      lz77_main_loop(bytes, pos + 1, size, encoder, hashes)
                    }
                  }
                }
              }
            }
          }
        }
      }
  }
}

fn byte_at_input(bytes: BitArray, pos: Int) -> Int {
  case bit_array.slice(bytes, pos, 1) {
    Ok(<<b>>) -> b
    _ -> 0
  }
}

fn lzma_hash3(b0: Int, b1: Int, b2: Int) -> Int {
  // Same Knuth-style mix as the deflate encoder — fits a 3-byte key
  // into a 16-bit bucket so the hash chain stays bounded.
  int.bitwise_and(
    int.bitwise_exclusive_or(
      int.bitwise_exclusive_or(b0 * 2_654_435_761, b1 * 40_503),
      b2 * 2_246_822_519,
    ),
    0xFFFF,
  )
}

fn lzma_match_length(
  bytes: BitArray,
  prev: Int,
  cur: Int,
  cap: Int,
  acc: Int,
) -> Int {
  case acc >= cap {
    True -> acc
    False ->
      case byte_at_input(bytes, prev + acc) == byte_at_input(bytes, cur + acc) {
        True -> lzma_match_length(bytes, prev, cur, cap, acc + 1)
        False -> acc
      }
  }
}

fn update_hashes_in_range(
  bytes: BitArray,
  hashes: dict.Dict(Int, Int),
  from: Int,
  to: Int,
  size: Int,
) -> dict.Dict(Int, Int) {
  case from >= to || from + lzma_lz77_min_match > size {
    True -> hashes
    False -> {
      let key =
        lzma_hash3(
          byte_at_input(bytes, from),
          byte_at_input(bytes, from + 1),
          byte_at_input(bytes, from + 2),
        )
      update_hashes_in_range(
        bytes,
        dict.insert(hashes, key, from),
        from + 1,
        to,
        size,
      )
    }
  }
}

fn emit_lzma_literal(
  encoder: Encoder,
  bytes: BitArray,
  pos: Int,
  byte: Int,
) -> Encoder {
  let pos_state = int.bitwise_and(pos, mask_for(encoder.props.pb))
  let encoder =
    encode_bit(
      encoder,
      prob_key(t_is_match, encoder.state * num_pos_states_max + pos_state),
      0,
    )
  let prev_byte = case pos {
    0 -> 0
    _ -> byte_at_input(bytes, pos - 1)
  }
  let lit_pos_state = int.bitwise_and(pos, mask_for(encoder.props.lp))
  let lit_high = int.bitwise_shift_right(prev_byte, 8 - encoder.props.lc)
  let context_index =
    int.bitwise_or(
      int.bitwise_shift_left(lit_pos_state, encoder.props.lc),
      lit_high,
    )
  let prob_base = context_index * 0x300
  let encoder = case encoder.state < 7 {
    True -> encode_literal_bits(encoder, prob_base, 1, byte, 8)
    False -> {
      // Matched-literal path: XOR against the byte at distance
      // `rep0 + 1` so the decoder's matched-literal state machine
      // sees the same context.
      let match_byte = byte_at_input(bytes, pos - encoder.rep0 - 1)
      encode_matched_literal_bits(
        encoder,
        prob_base,
        1,
        byte,
        match_byte,
        True,
        8,
      )
    }
  }
  Encoder(
    ..encoder,
    state: literal_state_after(encoder.state),
    output_len: encoder.output_len + 1,
  )
}

fn encode_matched_literal_bits(
  encoder: Encoder,
  base: Int,
  symbol: Int,
  byte: Int,
  match_byte: Int,
  matched: Bool,
  remaining: Int,
) -> Encoder {
  case remaining {
    0 -> encoder
    _ -> {
      let bit_pos = remaining - 1
      let bit = int.bitwise_and(int.bitwise_shift_right(byte, bit_pos), 1)
      case matched {
        True -> {
          let match_bit =
            int.bitwise_and(int.bitwise_shift_right(match_byte, bit_pos), 1)
          let prob_offset = 0x100 + match_bit * 0x100 + symbol
          let encoder =
            encode_bit(encoder, prob_key(t_literal, base + prob_offset), bit)
          encode_matched_literal_bits(
            encoder,
            base,
            symbol * 2 + bit,
            byte,
            match_byte,
            bit == match_bit,
            remaining - 1,
          )
        }
        False -> {
          let encoder =
            encode_bit(encoder, prob_key(t_literal, base + symbol), bit)
          encode_matched_literal_bits(
            encoder,
            base,
            symbol * 2 + bit,
            byte,
            match_byte,
            False,
            remaining - 1,
          )
        }
      }
    }
  }
}

fn emit_lzma_match(
  encoder: Encoder,
  pos_state: Int,
  length: Int,
  distance_value: Int,
) -> Encoder {
  // `is_match = 1` is shared between rep and new-distance matches.
  let encoder =
    encode_bit(
      encoder,
      prob_key(t_is_match, encoder.state * num_pos_states_max + pos_state),
      1,
    )
  // Reusing one of the last four match distances (rep matches) skips
  // the full pos-slot / direct-bits / alignment dance and saves
  // several bits per match.  Pick the lowest-numbered rep slot that
  // matches so the rep ring stays consistent with the decoder.
  case which_rep_slot(encoder, distance_value) {
    Some(slot) -> emit_lzma_rep_match(encoder, pos_state, length, slot)
    None ->
      emit_lzma_new_distance_match(encoder, pos_state, length, distance_value)
  }
}

fn which_rep_slot(encoder: Encoder, distance_value: Int) -> Option(Int) {
  case True {
    _ if distance_value == encoder.rep0 -> Some(0)
    _ if distance_value == encoder.rep1 -> Some(1)
    _ if distance_value == encoder.rep2 -> Some(2)
    _ if distance_value == encoder.rep3 -> Some(3)
    _ -> None
  }
}

fn emit_lzma_new_distance_match(
  encoder: Encoder,
  pos_state: Int,
  length: Int,
  distance_value: Int,
) -> Encoder {
  let encoder = encode_bit(encoder, prob_key(t_is_rep, encoder.state), 0)
  let encoder =
    encode_lzma_length(
      encoder,
      pos_state,
      length,
      t_len_choice,
      t_len_choice2,
      t_len_low,
      t_len_mid,
      t_len_high,
    )
  let encoder = encode_lzma_distance(encoder, distance_value, length)
  Encoder(
    ..encoder,
    state: lzma_match_next_state(encoder.state),
    rep3: encoder.rep2,
    rep2: encoder.rep1,
    rep1: encoder.rep0,
    rep0: distance_value,
    output_len: encoder.output_len + length,
  )
}

fn emit_lzma_rep_match(
  encoder: Encoder,
  pos_state: Int,
  length: Int,
  slot: Int,
) -> Encoder {
  // is_rep = 1 + the slot-selection prefix.
  let encoder = encode_bit(encoder, prob_key(t_is_rep, encoder.state), 1)
  let encoder = case slot {
    0 -> {
      let encoder = encode_bit(encoder, prob_key(t_is_rep_g0, encoder.state), 0)
      // is_rep0_long = 1 since we always carry a real length (no
      // short-rep length-1 optimisation yet — the literal-vs-short-rep
      // tradeoff requires comparing per-byte costs and is left for a
      // follow-up).
      encode_bit(
        encoder,
        prob_key(t_is_rep0_long, encoder.state * num_pos_states_max + pos_state),
        1,
      )
    }
    1 -> {
      let encoder = encode_bit(encoder, prob_key(t_is_rep_g0, encoder.state), 1)
      encode_bit(encoder, prob_key(t_is_rep_g1, encoder.state), 0)
    }
    2 -> {
      let encoder = encode_bit(encoder, prob_key(t_is_rep_g0, encoder.state), 1)
      let encoder = encode_bit(encoder, prob_key(t_is_rep_g1, encoder.state), 1)
      encode_bit(encoder, prob_key(t_is_rep_g2, encoder.state), 0)
    }
    _ -> {
      let encoder = encode_bit(encoder, prob_key(t_is_rep_g0, encoder.state), 1)
      let encoder = encode_bit(encoder, prob_key(t_is_rep_g1, encoder.state), 1)
      encode_bit(encoder, prob_key(t_is_rep_g2, encoder.state), 1)
    }
  }
  let encoder =
    encode_lzma_length(
      encoder,
      pos_state,
      length,
      t_rep_len_choice,
      t_rep_len_choice2,
      t_rep_len_low,
      t_rep_len_mid,
      t_rep_len_high,
    )
  let #(new_rep0, new_rep1, new_rep2, new_rep3) = case slot {
    0 -> #(encoder.rep0, encoder.rep1, encoder.rep2, encoder.rep3)
    1 -> #(encoder.rep1, encoder.rep0, encoder.rep2, encoder.rep3)
    2 -> #(encoder.rep2, encoder.rep0, encoder.rep1, encoder.rep3)
    _ -> #(encoder.rep3, encoder.rep0, encoder.rep1, encoder.rep2)
  }
  Encoder(
    ..encoder,
    state: lzma_rep_next_state(encoder.state),
    rep0: new_rep0,
    rep1: new_rep1,
    rep2: new_rep2,
    rep3: new_rep3,
    output_len: encoder.output_len + length,
  )
}

fn lzma_rep_next_state(state: Int) -> Int {
  case state < 7 {
    True -> 8
    False -> 11
  }
}

fn lzma_match_next_state(state: Int) -> Int {
  case state < 7 {
    True -> 7
    False -> 10
  }
}

fn encode_lzma_length(
  encoder: Encoder,
  pos_state: Int,
  length: Int,
  t_choice: Int,
  t_choice2: Int,
  t_low: Int,
  t_mid: Int,
  t_high: Int,
) -> Encoder {
  // length - match_min_len lives in 0..7 (low), 8..15 (mid), or
  // 16..271 (high).  Each tier prefixes its bit tree with the choice
  // bits that select it on the decoder side.
  let value = length - match_min_len
  case value < num_low_len {
    True -> {
      let encoder = encode_bit(encoder, prob_key(t_choice, 0), 0)
      encode_bit_tree(
        encoder,
        t_low,
        pos_state * num_low_len,
        num_low_len_bits,
        value,
      )
    }
    False ->
      case value < num_low_len + num_mid_len {
        True -> {
          let encoder = encode_bit(encoder, prob_key(t_choice, 0), 1)
          let encoder = encode_bit(encoder, prob_key(t_choice2, 0), 0)
          let mid_value = value - num_low_len
          encode_bit_tree(
            encoder,
            t_mid,
            pos_state * num_mid_len,
            num_mid_len_bits,
            mid_value,
          )
        }
        False -> {
          let encoder = encode_bit(encoder, prob_key(t_choice, 0), 1)
          let encoder = encode_bit(encoder, prob_key(t_choice2, 0), 1)
          let high_value = value - num_low_len - num_mid_len
          encode_bit_tree(encoder, t_high, 0, num_high_len_bits, high_value)
        }
      }
  }
}

fn encode_lzma_distance(encoder: Encoder, distance: Int, length: Int) -> Encoder {
  let len_state = case length - match_min_len < num_len_to_pos_states {
    True -> length - match_min_len
    False -> num_len_to_pos_states - 1
  }
  let pos_slot = compute_pos_slot(distance)
  let encoder =
    encode_bit_tree(encoder, t_pos_slot, len_state * 64, 6, pos_slot)
  case pos_slot < start_pos_model_index {
    True -> encoder
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
          let extra = distance - base
          encode_reverse_bit_tree(
            encoder,
            t_pos_dec,
            offset,
            num_direct_bits,
            extra,
          )
        }
        False -> {
          let high_bits = num_direct_bits - num_align_bits
          let extra = distance - base
          let top = int.bitwise_shift_right(extra, num_align_bits)
          let encoder = encode_direct_bits(encoder, top, high_bits)
          let align_value = int.bitwise_and(extra, mask_for(num_align_bits))
          encode_reverse_bit_tree(
            encoder,
            t_align,
            0,
            num_align_bits,
            align_value,
          )
        }
      }
    }
  }
}

fn compute_pos_slot(distance: Int) -> Int {
  case distance < 4 {
    True -> distance
    False -> {
      let high_bit = high_bit_pos(distance)
      let next_bit =
        int.bitwise_and(int.bitwise_shift_right(distance, high_bit - 1), 1)
      high_bit * 2 + next_bit
    }
  }
}

fn high_bit_pos(value: Int) -> Int {
  high_bit_pos_loop(value, 0)
}

fn high_bit_pos_loop(value: Int, pos: Int) -> Int {
  case value <= 1 {
    True -> pos
    False -> high_bit_pos_loop(int.bitwise_shift_right(value, 1), pos + 1)
  }
}

fn encode_bit_tree(
  encoder: Encoder,
  table: Int,
  base: Int,
  num_bits: Int,
  value: Int,
) -> Encoder {
  encode_bit_tree_loop(encoder, table, base, num_bits, 1, value)
}

fn encode_bit_tree_loop(
  encoder: Encoder,
  table: Int,
  base: Int,
  remaining: Int,
  context: Int,
  value: Int,
) -> Encoder {
  case remaining {
    0 -> encoder
    _ -> {
      let bit_pos = remaining - 1
      let bit = int.bitwise_and(int.bitwise_shift_right(value, bit_pos), 1)
      let encoder = encode_bit(encoder, prob_key(table, base + context), bit)
      encode_bit_tree_loop(
        encoder,
        table,
        base,
        remaining - 1,
        context * 2 + bit,
        value,
      )
    }
  }
}

fn encode_reverse_bit_tree(
  encoder: Encoder,
  table: Int,
  base: Int,
  num_bits: Int,
  value: Int,
) -> Encoder {
  encode_reverse_bit_tree_loop(encoder, table, base, num_bits, 1, value, 0)
}

fn encode_reverse_bit_tree_loop(
  encoder: Encoder,
  table: Int,
  base: Int,
  remaining: Int,
  context: Int,
  value: Int,
  emitted: Int,
) -> Encoder {
  case remaining {
    0 -> encoder
    _ -> {
      let bit = int.bitwise_and(int.bitwise_shift_right(value, emitted), 1)
      let encoder = encode_bit(encoder, prob_key(table, base + context), bit)
      encode_reverse_bit_tree_loop(
        encoder,
        table,
        base,
        remaining - 1,
        context * 2 + bit,
        value,
        emitted + 1,
      )
    }
  }
}

fn encode_direct_bits(encoder: Encoder, value: Int, num_bits: Int) -> Encoder {
  encode_direct_bits_loop(encoder, value, num_bits)
}

fn encode_direct_bits_loop(
  encoder: Encoder,
  value: Int,
  remaining: Int,
) -> Encoder {
  case remaining {
    0 -> encoder
    _ -> {
      let bit_pos = remaining - 1
      let bit = int.bitwise_and(int.bitwise_shift_right(value, bit_pos), 1)
      let encoder = encode_direct_bit(encoder, bit)
      encode_direct_bits_loop(encoder, value, remaining - 1)
    }
  }
}

fn encode_direct_bit(encoder: Encoder, bit: Int) -> Encoder {
  // Equal-probability bit: split the range exactly in half and bump
  // `low` for a 1.
  let new_range = int.bitwise_shift_right(encoder.range, 1)
  let encoder = case bit {
    0 -> Encoder(..encoder, range: new_range)
    _ -> Encoder(..encoder, low: encoder.low + new_range, range: new_range)
  }
  normalize_encoder(encoder)
}
