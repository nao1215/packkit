//// BCJ2 (Branch / Call / Jump x86 converter, version 2) decoder.
////
//// BCJ2 is the demux half of the encoder p7zip uses by default for
//// x86 binaries.  The encoder walks an x86 instruction stream and,
//// when it sees a `CALL rel32` (0xE8 imm32), `JMP rel32` (0xE9
//// imm32), or `Jcc rel32` (0x0F 0x8x imm32), uses an adaptive range
//// coder to decide whether the bytes look like a "real" branch.
//// Real branches have their 32-bit operand converted to absolute
//// address and routed to a side stream (`call` for E8s, `jump` for
//// E9s + Jccs); the main stream keeps the 1- or 2-byte opcode.
//// LZMA then compresses each stream separately — branch destinations
//// share a small distribution, so factoring them out shrinks the
//// archive meaningfully.
////
//// The decoder is the reverse: read main bytes, copy them through,
//// and on every potential branch opcode consult the range coder to
//// see whether the next 4 bytes should be reconstructed from the
//// `call` / `jump` stream as a relative offset.  Reference is the
//// LZMA-SDK `C/Bcj2.c` (Igor Pavlov, public domain, 2018-04-28)
//// translated to a one-shot pure-Gleam loop.
////
//// Cross-target by construction; the algorithm uses 32-bit unsigned
//// arithmetic and we mask with 0xFFFFFFFF after every shift to keep
//// the model behaviour identical on Erlang (arbitrary-precision
//// ints) and JavaScript (53-bit floats).

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/order
import gleam/result

/// Decoder failure reasons.  Always typed so callers can map to
/// their own error type without parsing strings.
pub type Bcj2Error {
  /// The range-coder header (first 5 bytes of the rc stream) was
  /// short or malformed (first byte must be 0).
  RangeCoderHeaderInvalid
  /// The decoder needed more bytes from a stream but the stream is
  /// already exhausted.
  StreamExhausted(stream_name: String)
  /// The decoded length doesn't match the declared output size.
  OutputSizeMismatch(declared: Int, actual: Int)
}

const top_value: Int = 0x1000000

// 2^24

const num_model_bits: Int = 11

const bit_model_total: Int = 0x800

// 1 << 11

const num_move_bits: Int = 5

const u32_mask: Int = 0xFFFFFFFF

// Number of probability slots in the BCJ2 model.  Index layout:
//   0     — Jcc (0x0F 0x8x) bit
//   1     — JMP (0xE9) bit
//   2..257 — CALL (0xE8) bit, indexed by the byte that PRECEDED the
//           0xE8 in the output stream.  (See p7zip's `prob` lookup.)
const num_probs: Int = 258

const prob_jcc: Int = 0

const prob_jmp: Int = 1

const prob_call_base: Int = 2

/// Decode a BCJ2-converted x86 binary.  All four input streams are
/// passed as fully buffered `BitArray`s; the decoder reads them in
/// the order p7zip's `Bcj2.c` expects (`MAIN`, `CALL`, `JUMP`, `RC`).
/// `output_size` is the declared output length from the folder's
/// `CodersUnPackSize` entry — we use it to size the output buffer
/// and to detect a truncated decode.
pub fn decode(
  main main: BitArray,
  call call: BitArray,
  jump jump: BitArray,
  range_coder rc: BitArray,
  output_size output_size: Int,
) -> Result(BitArray, Bcj2Error) {
  use #(code, rc_rest) <- result.try(init_range_coder(rc))
  let probs = init_probs(0, dict.new())
  let initial =
    State(
      main: main,
      call: call,
      jump: jump,
      rc: rc_rest,
      probs: probs,
      range: u32_mask,
      code: code,
      ip: 0,
      prev_byte: 0,
      output: <<>>,
      output_size: output_size,
    )
  use final_state <- result.try(decode_loop(initial))
  let actual = bit_array.byte_size(final_state.output)
  case actual == output_size {
    True -> Ok(final_state.output)
    False -> Error(OutputSizeMismatch(declared: output_size, actual: actual))
  }
}

// -- internal state -------------------------------------------------

type State {
  State(
    main: BitArray,
    call: BitArray,
    jump: BitArray,
    rc: BitArray,
    probs: Dict(Int, Int),
    range: Int,
    code: Int,
    ip: Int,
    prev_byte: Int,
    output: BitArray,
    output_size: Int,
  )
}

fn init_probs(index: Int, acc: Dict(Int, Int)) -> Dict(Int, Int) {
  // Tail-recursive self call → branch via `int.compare` rather than
  // `bool.guard`, otherwise the JS backend can't rewrite the call to
  // a `while` loop.  See feedback-gleam-tail-call-bool-guard in
  // memory.
  case int.compare(index, num_probs) {
    order.Lt ->
      init_probs(index + 1, dict.insert(acc, index, bit_model_total / 2))
    _ -> acc
  }
}

// Initialize the range coder: the first 5 bytes of the rc stream are
// `00` + 4 big-endian bytes that become the initial `code` value.
fn init_range_coder(rc: BitArray) -> Result(#(Int, BitArray), Bcj2Error) {
  case rc {
    <<first, c1, c2, c3, c4, rest:bytes>> ->
      case first == 0 {
        True -> {
          let code =
            int.bitwise_or(
              int.bitwise_or(
                int.bitwise_shift_left(c1, 24),
                int.bitwise_shift_left(c2, 16),
              ),
              int.bitwise_or(int.bitwise_shift_left(c3, 8), c4),
            )
          Ok(#(code, rest))
        }
        False -> Error(RangeCoderHeaderInvalid)
      }
    _ -> Error(RangeCoderHeaderInvalid)
  }
}

// -- main loop ------------------------------------------------------

fn decode_loop(state: State) -> Result(State, Bcj2Error) {
  // Self-recursive tail call — keep the exit check as `int.compare`
  // so the JS backend rewrites this to a `while` (see
  // feedback-gleam-tail-call-bool-guard).  For the same reason the
  // step is split into `decode_loop_step` so the nesting stays under
  // the lint's deep_nesting threshold.
  case int.compare(bit_array.byte_size(state.output), state.output_size) {
    order.Lt -> decode_loop_step(state)
    _ -> Ok(state)
  }
}

fn decode_loop_step(state: State) -> Result(State, Bcj2Error) {
  case state.main {
    <<>> -> Ok(state)
    <<byte, main_rest:bytes>> -> {
      let after_consume = consume_main_byte(state, byte, main_rest)
      use stepped <- result.try(decode_main_byte(
        after_consume,
        byte,
        state.prev_byte,
      ))
      decode_loop(stepped)
    }
    _ -> Error(StreamExhausted(stream_name: "main"))
  }
}

fn decode_main_byte(
  state: State,
  byte: Int,
  prev_byte_before_consume: Int,
) -> Result(State, Bcj2Error) {
  case is_branch_candidate(byte, prev_byte_before_consume) {
    False -> Ok(state)
    True -> decode_branch(state, byte)
  }
}

// Read a single byte from the main stream, append it to the output,
// and update the "last byte we wrote" register used by the next
// branch-candidate check.
fn consume_main_byte(state: State, byte: Int, main_rest: BitArray) -> State {
  State(
    ..state,
    main: main_rest,
    output: <<state.output:bits, byte>>,
    ip: state.ip + 1,
    prev_byte: byte,
  )
}

// Branch candidates per p7zip's loop:
//   - The byte itself is 0xE8 (CALL) or 0xE9 (JMP)
//   - OR the byte is in 0x80..0x8F (Jcc opcode) AND the previous
//     byte we emitted was 0x0F (the Jcc prefix).
fn is_branch_candidate(byte: Int, prev_byte: Int) -> Bool {
  case byte {
    0xE8 -> True
    0xE9 -> True
    _ ->
      case prev_byte == 0x0F && int.bitwise_and(byte, 0xF0) == 0x80 {
        True -> True
        False -> False
      }
  }
}

// We just emitted a branch opcode at output offset (ip - 1).  Use the
// range coder to decide whether this is a real branch; if so, read 4
// bytes from the appropriate destination stream, convert to a
// relative offset, and write LE32 to the output.
fn decode_branch(state: State, opcode: Int) -> Result(State, Bcj2Error) {
  let prob_index = case opcode {
    0xE8 -> prob_call_base + prev_byte_for_call(state)
    0xE9 -> prob_jmp
    _ -> prob_jcc
  }
  // `init_probs` seeded every slot in 0..258 so this `result.unwrap`
  // never falls back in practice; the `or:` value matches the seed
  // so we stay correct even if a future refactor changes the table
  // shape.
  let prob =
    dict.get(state.probs, prob_index) |> result.unwrap(or: bit_model_total / 2)
  let #(bit, range_after, code_after, prob_after) =
    range_decode_bit(state.range, state.code, prob)
  let probs_after = dict.insert(state.probs, prob_index, prob_after)
  let intermediate =
    State(..state, range: range_after, code: code_after, probs: probs_after)
  use refilled <- result.try(maybe_refill_rc(intermediate))
  case bit {
    0 -> Ok(refilled)
    _ -> emit_branch_target(refilled, opcode)
  }
}

// The CALL probability index uses the byte THAT PRECEDED the 0xE8 in
// the output stream — which is `state.prev_byte` after we just
// emitted 0xE8.  But `consume_main_byte` already overwrote
// `prev_byte` to 0xE8, so we look up the byte just before the
// trailing 0xE8 in the output buffer.  For outputs shorter than 2
// bytes we fall back to 0 (matches p7zip's `prev` initialiser).
fn prev_byte_for_call(state: State) -> Int {
  let output_size = bit_array.byte_size(state.output)
  case output_size < 2 {
    True -> 0
    False ->
      case bit_array.slice(state.output, output_size - 2, 1) {
        Ok(<<single>>) -> single
        _ -> 0
      }
  }
}

// 11-bit binary range coder bit decode (LZMA-SDK conventions).
// Returns the decoded bit plus the new (range, code, prob) triple.
fn range_decode_bit(range: Int, code: Int, prob: Int) -> #(Int, Int, Int, Int) {
  let bound =
    int.bitwise_shift_right(range, num_model_bits)
    |> int.multiply(prob)
    |> int.bitwise_and(u32_mask)
  case code < bound {
    True -> {
      // Bit 0: shrink range to bound, increase prob.
      let new_prob =
        prob + int.bitwise_shift_right(bit_model_total - prob, num_move_bits)
      #(0, bound, code, new_prob)
    }
    False -> {
      // Bit 1: chop bound off range + code, decrease prob.
      let new_range = int.bitwise_and(range - bound, u32_mask)
      let new_code = int.bitwise_and(code - bound, u32_mask)
      let new_prob = prob - int.bitwise_shift_right(prob, num_move_bits)
      #(1, new_range, new_code, new_prob)
    }
  }
}

// When `range` drops below `top_value` (2^24), the range coder
// normalises by shifting the next rc-stream byte into the low byte
// of `code` and the range.  Loops until `range >= top_value`.
fn maybe_refill_rc(state: State) -> Result(State, Bcj2Error) {
  // Self-recursive — branch on `int.compare` to keep the JS tail
  // call alive (see feedback-gleam-tail-call-bool-guard).
  case int.compare(state.range, top_value) {
    order.Lt -> refill_rc_step(state)
    _ -> Ok(state)
  }
}

fn refill_rc_step(state: State) -> Result(State, Bcj2Error) {
  case state.rc {
    <<next, rc_rest:bytes>> -> {
      let new_range =
        int.bitwise_shift_left(state.range, 8) |> int.bitwise_and(u32_mask)
      let new_code =
        int.bitwise_or(int.bitwise_shift_left(state.code, 8), next)
        |> int.bitwise_and(u32_mask)
      maybe_refill_rc(
        State(..state, range: new_range, code: new_code, rc: rc_rest),
      )
    }
    _ -> Error(StreamExhausted(stream_name: "range_coder"))
  }
}

// Read 4 big-endian bytes from the appropriate destination stream,
// compute `relative = target - (ip + 4)`, and write the 4 bytes
// little-endian to the output.  Bumps `ip` by 4 to match p7zip.
fn emit_branch_target(state: State, opcode: Int) -> Result(State, Bcj2Error) {
  let #(dest_stream, dest_label) = case opcode == 0xE8 {
    True -> #(state.call, "call")
    False -> #(state.jump, "jump")
  }
  case dest_stream {
    <<b0, b1, b2, b3, dest_rest:bytes>> -> {
      let target =
        int.bitwise_or(
          int.bitwise_or(
            int.bitwise_shift_left(b0, 24),
            int.bitwise_shift_left(b1, 16),
          ),
          int.bitwise_or(int.bitwise_shift_left(b2, 8), b3),
        )
      let new_ip = state.ip + 4
      let relative = int.bitwise_and(target - new_ip, u32_mask)
      let r0 = int.bitwise_and(relative, 0xFF)
      let r1 = int.bitwise_and(int.bitwise_shift_right(relative, 8), 0xFF)
      let r2 = int.bitwise_and(int.bitwise_shift_right(relative, 16), 0xFF)
      let r3 = int.bitwise_and(int.bitwise_shift_right(relative, 24), 0xFF)
      let new_output = <<state.output:bits, r0, r1, r2, r3>>
      let next_state =
        State(..state, ip: new_ip, output: new_output, prev_byte: r3)
      case opcode == 0xE8 {
        True -> Ok(State(..next_state, call: dest_rest))
        False -> Ok(State(..next_state, jump: dest_rest))
      }
    }
    _ -> Error(StreamExhausted(stream_name: dest_label))
  }
}
