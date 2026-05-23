//// Brotli codec — pure-Gleam decoder.
////
//// Decodes RFC 7932 brotli streams whose metablocks use a single
//// block type for each of the literal, insert-and-copy, and
//// distance categories (i.e. `NBLTYPES = 1` and `NTREES = 1` for
//// both literal and distance categories — the case brotli's stock
//// encoder emits for the overwhelming majority of inputs).  Within
//// that envelope it handles:
////
//// * The canonical empty stream `0x3F`.
//// * Any stream that uses uncompressed metablocks
////   (`ISUNCOMPRESSED` bit set).
//// * Compressed metablocks with both simple-form (RFC 7932 §3.4)
////   and complex-form (§3.5) prefix-code descriptors.
//// * The command loop (§4): insert-and-copy alphabet → literals
////   from the literal prefix code → distance code → LZ77 copy from
////   the sliding window, with the 4-entry recent-distance ring
////   buffer.
//// * Static-dictionary references (§8): any command whose
////   resolved distance exceeds the current output position falls
////   back to the embedded 122 KiB dictionary, with the prefix /
////   suffix / `OMIT_FIRST` / `OMIT_LAST` / `UPPERCASE_FIRST` /
////   `UPPERCASE_ALL` transforms applied per `transform_idx`.
////
//// What still returns a typed `CodecNotImplemented`:
////
//// * Block switching (NBLTYPES > 1).
//// * Context maps (NTREES > 1) for the literal or distance trees.
//// * The `SHIFT_FIRST` / `SHIFT_ALL` transforms used by the shared-
////   dictionary extension (the basic RFC 7932 transform set never
////   selects them).

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/result
import packkit/codec as codecs
import packkit/error
import packkit/internal/brotli_context as brotli_ctx
import packkit/internal/brotli_dictionary as brotli_dict
import packkit/internal/brotli_transform as brotli_xfm
import packkit/limit

/// Brotli codec smart constructor.
pub fn codec() -> codecs.Codec {
  codecs.brotli()
}

/// Encode `bytes` as a Brotli stream.  Not yet implemented.
pub fn encode(bytes _bytes: BitArray) -> Result(BitArray, error.CodecError) {
  Error(error.CodecNotImplemented(feature: "brotli.encode"))
}

/// Decode a Brotli stream using default limits.
pub fn decode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  decode_with_limits(bytes: bytes, limits: limit.default())
}

/// Decode a Brotli stream using explicit limits.
pub fn decode_with_limits(
  bytes bytes: BitArray,
  limits limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  use <- bool.guard(
    when: bit_array.byte_size(bytes) > limit.max_input_bytes(limits),
    return: Error(error.CodecLimitExceeded(
      limit: "max_input_bytes",
      value: bit_array.byte_size(bytes),
    )),
  )

  let reader = new_reader(bytes)
  use #(_wbits, reader) <- result.try(read_wbits(reader))
  decode_metablocks(reader, <<>>, new_ring(), limits)
}

// -- metablock loop -----------------------------------------------------

fn decode_metablocks(
  reader: Reader,
  output: BitArray,
  ring: DistRing,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  use #(is_last, reader) <- result.try(read_bits(reader, 1))
  case is_last {
    1 -> {
      use #(is_last_empty, reader) <- result.try(read_bits(reader, 1))
      case is_last_empty {
        1 -> Ok(output)
        _ -> {
          use #(output, _ring, _reader) <- result.try(decode_one_metablock(
            reader,
            output,
            ring,
            limits,
            True,
          ))
          Ok(output)
        }
      }
    }
    _ -> {
      use #(output, ring, reader) <- result.try(decode_one_metablock(
        reader,
        output,
        ring,
        limits,
        False,
      ))
      decode_metablocks(reader, output, ring, limits)
    }
  }
}

fn decode_one_metablock(
  reader: Reader,
  output: BitArray,
  ring: DistRing,
  limits: limit.Limits,
  is_last: Bool,
) -> Result(#(BitArray, DistRing, Reader), error.CodecError) {
  use #(mnibbles_raw, reader) <- result.try(read_bits(reader, 2))
  let mnibbles = case mnibbles_raw {
    0 -> 4
    1 -> 5
    2 -> 6
    _ -> 0
  }
  case mnibbles {
    0 -> decode_skip_metablock(reader, output, ring)
    _ -> decode_sized_metablock(reader, output, ring, limits, is_last, mnibbles)
  }
}

fn decode_sized_metablock(
  reader: Reader,
  output: BitArray,
  ring: DistRing,
  limits: limit.Limits,
  is_last: Bool,
  mnibbles: Int,
) -> Result(#(BitArray, DistRing, Reader), error.CodecError) {
  use #(mlen_minus_1, reader) <- result.try(read_bits(reader, mnibbles * 4))
  let mlen = mlen_minus_1 + 1
  use #(is_uncompressed, reader) <- result.try(case is_last {
    True -> Ok(#(0, reader))
    False -> read_bits(reader, 1)
  })
  case is_uncompressed {
    1 -> decode_uncompressed_metablock(reader, output, ring, mlen, limits)
    _ -> decode_compressed_metablock(reader, output, ring, mlen, limits)
  }
}

// -- Compressed metablock (RFC 7932 §9.2) ------------------------------
//
// Parses the full header, builds the three prefix codes, then enters
// the command loop in `run_commands`.  Block switching (NBLTYPES > 1),
// context maps (NTREES > 1), and static-dictionary references are
// still surfaced as `CodecNotImplemented`.

fn decode_compressed_metablock(
  reader: Reader,
  output: BitArray,
  ring: DistRing,
  mlen: Int,
  limits: limit.Limits,
) -> Result(#(BitArray, DistRing, Reader), error.CodecError) {
  use #(nbl_literal, reader) <- result.try(decode_var_len_uint8(reader))
  use #(nbl_command, reader) <- result.try(decode_var_len_uint8(reader))
  use #(nbl_distance, reader) <- result.try(decode_var_len_uint8(reader))

  use _ <- result.try(reject_block_switching("literal", nbl_literal))
  use _ <- result.try(reject_block_switching("insert-and-copy", nbl_command))
  use _ <- result.try(reject_block_switching("distance", nbl_distance))

  use #(npostfix, reader) <- result.try(read_bits(reader, 2))
  use #(ndirect_code, reader) <- result.try(read_bits(reader, 4))
  let ndirect = int.bitwise_shift_left(ndirect_code, npostfix)

  use #(context_modes, reader) <- result.try(
    read_context_modes(reader, nbl_literal, []),
  )

  use #(ntrees_literal, reader) <- result.try(decode_var_len_uint8(reader))
  use #(literal_context_map, reader) <- result.try(decode_context_map(
    reader,
    ntrees_literal,
    nbl_literal * 64,
  ))

  use #(ntrees_distance, reader) <- result.try(decode_var_len_uint8(reader))
  use #(distance_context_map, reader) <- result.try(decode_context_map(
    reader,
    ntrees_distance,
    nbl_distance * 4,
  ))

  let literal_alphabet = 256
  let command_alphabet = 704
  let distance_alphabet = 16 + ndirect + int.bitwise_shift_left(48, npostfix)

  use #(literal_codes, reader) <- result.try(
    decode_prefix_codes(reader, ntrees_literal, literal_alphabet, "literal", []),
  )
  use #(command_codes, reader) <- result.try(
    decode_prefix_codes(
      reader,
      nbl_command,
      command_alphabet,
      "insert-and-copy",
      [],
    ),
  )
  use #(distance_codes, reader) <- result.try(
    decode_prefix_codes(
      reader,
      ntrees_distance,
      distance_alphabet,
      "distance",
      [],
    ),
  )

  let pos = bit_array.byte_size(output)
  let state =
    CommandState(
      output: output,
      ring: ring,
      remaining: mlen,
      literal_codes: literal_codes,
      command_codes: command_codes,
      distance_codes: distance_codes,
      npostfix: npostfix,
      ndirect: ndirect,
      context_modes: context_modes,
      literal_context_map: literal_context_map,
      distance_context_map: distance_context_map,
      prev1: byte_at_or_zero(output, pos - 1),
      prev2: byte_at_or_zero(output, pos - 2),
      limits: limits,
    )
  use #(new_output, new_ring, reader) <- result.try(run_commands(reader, state))
  Ok(#(new_output, new_ring, reader))
}

fn byte_at_or_zero(bytes: BitArray, idx: Int) -> Int {
  case idx < 0 {
    True -> 0
    False ->
      case bit_array.slice(bytes, idx, 1) {
        Ok(<<b>>) -> b
        _ -> 0
      }
  }
}

// -- Distance ring buffer (RFC 7932 §4) --------------------------------

/// Brotli's 4-entry recent-distance buffer.  `idx` advances on every
/// recorded distance; reading the kᵗʰ-most-recent distance uses
/// `slots[(idx - 1 - k) & 3]`.  Initial values from RFC 7932 §4.
type DistRing {
  DistRing(idx: Int, d0: Int, d1: Int, d2: Int, d3: Int)
}

fn new_ring() -> DistRing {
  DistRing(idx: 0, d0: 16, d1: 15, d2: 11, d3: 4)
}

fn ring_get(r: DistRing, slot: Int) -> Int {
  case int.bitwise_and(slot, 3) {
    0 -> r.d0
    1 -> r.d1
    2 -> r.d2
    _ -> r.d3
  }
}

fn ring_set(r: DistRing, slot: Int, value: Int) -> DistRing {
  case int.bitwise_and(slot, 3) {
    0 -> DistRing(..r, d0: value)
    1 -> DistRing(..r, d1: value)
    2 -> DistRing(..r, d2: value)
    _ -> DistRing(..r, d3: value)
  }
}

/// Write `distance` to the current slot then advance `idx`.  This is
/// the post-decode step for every command's distance, including the
/// reused "code 0" case (where the same value is written back).
fn ring_push(ring: DistRing, distance: Int) -> DistRing {
  let updated = ring_set(ring, ring.idx, distance)
  DistRing(..updated, idx: updated.idx + 1)
}

// -- Command loop (RFC 7932 §4) ----------------------------------------
//
// One pass through the metablock body emits literals and copies until
// MLEN bytes have been produced.  Each iteration:
//
//   1. Decode an insert-and-copy symbol from the command prefix code
//      and turn it into `(insert_len, copy_len, dist_code, context)`
//      via `cmd_lut`.
//   2. Read `insert_len_extra` and `copy_len_extra` bits.
//   3. Emit `insert_len` literals from the literal prefix code.
//   4. If we still have bytes to produce, decode a distance code from
//      the distance prefix code (unless the I+C entry's `dist_code`
//      is `-1`, meaning "reuse the most recent distance"), resolve it
//      against the ring buffer, and copy `copy_len` bytes from
//      `output[pos - distance ..]`.
//
// The runtime state for one metablock is bundled in `CommandState` so
// the (already pretty long) command-loop recurrences stay readable.

type CommandState {
  CommandState(
    output: BitArray,
    ring: DistRing,
    remaining: Int,
    literal_codes: List(PrefixCode),
    command_codes: List(PrefixCode),
    distance_codes: List(PrefixCode),
    npostfix: Int,
    ndirect: Int,
    context_modes: List(Int),
    /// `nbl_literal × 64` entries (or empty when NTREESL = 1).  Indexed
    /// by `block_type_l × 64 + literal_context_id`.
    literal_context_map: BitArray,
    /// `nbl_distance × 4` entries (or empty when NTREESD = 1).  Indexed
    /// by `block_type_d × 4 + distance_context`.
    distance_context_map: BitArray,
    /// Most recent literal byte (for context computation).
    prev1: Int,
    /// Second-most-recent literal byte.
    prev2: Int,
    limits: limit.Limits,
  )
}

fn run_commands(
  reader: Reader,
  state: CommandState,
) -> Result(#(BitArray, DistRing, Reader), error.CodecError) {
  case state.remaining <= 0 {
    True -> Ok(#(state.output, state.ring, reader))
    False -> {
      let assert [command_tree, ..] = state.command_codes
      use #(cmd, reader) <- result.try(decode_command(reader, command_tree))
      use #(state, reader) <- result.try(emit_literals(
        reader,
        state,
        cmd.insert_len,
      ))
      case state.remaining <= 0 {
        True -> Ok(#(state.output, state.ring, reader))
        False -> execute_copy_step(reader, state, cmd)
      }
    }
  }
}

fn execute_copy_step(
  reader: Reader,
  state: CommandState,
  cmd: Command,
) -> Result(#(BitArray, DistRing, Reader), error.CodecError) {
  use #(distance, push_to_ring, reader) <- result.try(decode_distance_value(
    reader,
    state,
    cmd,
  ))
  let pos = bit_array.byte_size(state.output)
  let is_dict_ref = distance > pos
  let ring = case push_to_ring && !is_dict_ref {
    True -> ring_push(state.ring, distance)
    False -> state.ring
  }
  let state = CommandState(..state, ring: ring)
  use state <- result.try(perform_copy(state, distance, cmd.copy_len, pos))
  run_commands(reader, state)
}

/// Decode the command's distance and report whether normal in-window
/// copies should push it onto the ring buffer.  Matches brotli's
/// `kCmdLut[].distance_code` convention:
///
/// * `0` — implicit reuse: take the most-recent distance from the
///   ring buffer and DO NOT advance it (the slot already holds that
///   value).  Used when the I+C `cell_idx < 2`.
/// * `-1` — read a distance code from the distance prefix tree and
///   resolve it via short-code, direct, or long-code paths.  Used
///   when the I+C `cell_idx ≥ 2`.
fn decode_distance_value(
  reader: Reader,
  state: CommandState,
  cmd: Command,
) -> Result(#(Int, Bool, Reader), error.CodecError) {
  case cmd.distance_code {
    0 -> {
      // Implicit reuse — no distance bits in the stream.
      let distance = ring_get(state.ring, state.ring.idx - 1)
      Ok(#(distance, False, reader))
    }
    _ -> {
      let distance_tree =
        pick_tree_by_index(
          state.distance_codes,
          select_distance_tree_idx(state, cmd.distance_context),
        )
      use #(code, reader) <- result.try(decode_prefix_symbol(
        reader,
        distance_tree,
      ))
      case code < 16 {
        True -> {
          let #(distance, push) = short_distance(code, state.ring)
          Ok(#(distance, push, reader))
        }
        False ->
          case code < 16 + state.ndirect {
            True -> Ok(#(code - 15, True, reader))
            False ->
              apply_long_distance(reader, code, state.npostfix, state.ndirect)
          }
      }
    }
  }
}

fn short_distance(code: Int, ring: DistRing) -> #(Int, Bool) {
  case code <= 3 {
    True -> {
      // Codes 0..3 read the kᵗʰ-most-recent distance.  Code 0 reuses
      // the slot the ring already holds, so we skip the ring push.
      let offset = code - 3
      let distance = ring_get(ring, ring.idx - offset)
      #(distance, code != 0)
    }
    False -> {
      // Codes 4..15: six derived offsets from ring[0] or ring[3].
      // delta table from C `0x605142` packed-nibble lookup.
      let #(base, index_delta) = case code < 10 {
        True -> #(code - 4, 3)
        False -> #(code - 10, 2)
      }
      let pre_delta =
        int.bitwise_and(int.bitwise_shift_right(0x60_5142, 4 * base), 0xF)
      let delta = pre_delta - 3
      let distance = ring_get(ring, ring.idx + index_delta) + delta
      #(distance, True)
    }
  }
}

/// Long-distance branch: read `extra_bits` extra bits and combine with
/// the per-code base offset.  Returns `push_to_ring = True`; the
/// caller suppresses the push if the resolved distance turns out to
/// be a static-dictionary reference.
fn apply_long_distance(
  reader: Reader,
  distance_code: Int,
  npostfix: Int,
  ndirect: Int,
) -> Result(#(Int, Bool, Reader), error.CodecError) {
  let #(extra_bits, base) =
    long_distance_params(distance_code, npostfix, ndirect)
  use #(extra, reader) <- result.try(read_bits(reader, extra_bits))
  let distance = base + int.bitwise_shift_left(extra, npostfix)
  Ok(#(distance, True, reader))
}

/// Per RFC 7932 §4 the long-distance code group `g` (counting from 0)
/// has `bits = g/2 + 1` extra bits.  Each group holds `2^npostfix`
/// codes that share `bits` and differ in their low `npostfix` bits.
/// The base offset for group `g`, sub-code `j`, is
///   NDIRECT + (((2 + (g % 2)) << bits - 4) << npostfix) + 1 + j
fn long_distance_params(code: Int, npostfix: Int, ndirect: Int) -> #(Int, Int) {
  let postfix = int.bitwise_shift_left(1, npostfix)
  let i_relative = code - 16 - ndirect
  let group_idx = i_relative / postfix
  let within_group = i_relative % postfix
  let bits = group_idx / 2 + 1
  let half = group_idx % 2
  let pre = int.bitwise_shift_left(2 + half, bits) - 4
  let base = ndirect + int.bitwise_shift_left(pre, npostfix) + 1 + within_group
  #(bits, base)
}

fn perform_copy(
  state: CommandState,
  distance: Int,
  copy_len: Int,
  pos: Int,
) -> Result(CommandState, error.CodecError) {
  case distance > pos {
    True -> dictionary_copy(state, distance, copy_len, pos)
    False -> in_window_copy(state, distance, copy_len, pos)
  }
}

fn in_window_copy(
  state: CommandState,
  distance: Int,
  copy_len: Int,
  pos: Int,
) -> Result(CommandState, error.CodecError) {
  let actual = int.min(copy_len, state.remaining)
  let new_output = lz77_copy(state.output, distance, actual, pos)
  let projected = bit_array.byte_size(new_output)
  use <- bool.guard(
    when: projected > limit.max_output_bytes(state.limits),
    return: Error(error.CodecLimitExceeded(
      limit: "max_output_bytes",
      value: projected,
    )),
  )
  Ok(refresh_prev_bytes(
    CommandState(
      ..state,
      output: new_output,
      remaining: state.remaining - actual,
    ),
  ))
}

/// Resolve a copy whose distance exceeds the current output position
/// against the RFC 7932 §8 static dictionary.  `address = distance -
/// pos - 1` is split into a word index (low `size_bits(copy_len)`
/// bits) and a transform index (the rest).  The selected dictionary
/// word is run through the chosen transform — which may add a prefix
/// or suffix, omit characters at either end, or uppercase part of the
/// word — and the resulting bytes are appended to the output.
fn dictionary_copy(
  state: CommandState,
  distance: Int,
  copy_len: Int,
  pos: Int,
) -> Result(CommandState, error.CodecError) {
  let shift = brotli_dict.size_bits(copy_len)
  use <- bool.guard(
    when: shift == 0,
    return: Error(error.CodecInvalidData(
      message: "brotli dictionary reference at length "
      <> int.to_string(copy_len)
      <> " (valid range 4..24)",
    )),
  )
  let address = distance - pos - 1
  let mask = int.bitwise_shift_left(1, shift) - 1
  let word_idx = int.bitwise_and(address, mask)
  let transform_idx = int.bitwise_shift_right(address, shift)
  use <- bool.guard(
    when: transform_idx >= brotli_xfm.num_transforms,
    return: Error(error.CodecInvalidData(
      message: "brotli dictionary transform index "
      <> int.to_string(transform_idx)
      <> " out of range",
    )),
  )
  let dict_offset = brotli_dict.offset(copy_len) + word_idx * copy_len
  let assert Ok(word) = bit_array.slice(brotli_dict.data, dict_offset, copy_len)
  let transformed = brotli_xfm.apply(word, transform_idx)
  let transformed_len = bit_array.byte_size(transformed)
  let truncated_len = int.min(transformed_len, state.remaining)
  let actual_bytes = case truncated_len == transformed_len {
    True -> transformed
    False -> {
      let assert Ok(slice) = bit_array.slice(transformed, 0, truncated_len)
      slice
    }
  }
  let new_output = bit_array.concat([state.output, actual_bytes])
  let projected = bit_array.byte_size(new_output)
  use <- bool.guard(
    when: projected > limit.max_output_bytes(state.limits),
    return: Error(error.CodecLimitExceeded(
      limit: "max_output_bytes",
      value: projected,
    )),
  )
  Ok(refresh_prev_bytes(
    CommandState(
      ..state,
      output: new_output,
      remaining: state.remaining - truncated_len,
    ),
  ))
}

/// LZ77-style self-overlapping copy: emit `count` bytes by reading
/// `output[pos - distance]` and appending it, then incrementing pos.
/// Works correctly for `distance < count` because each emitted byte
/// updates the source.
fn lz77_copy(output: BitArray, distance: Int, count: Int, pos: Int) -> BitArray {
  case count {
    0 -> output
    _ -> {
      let src = pos - distance
      let assert Ok(<<byte>>) = bit_array.slice(output, src, 1)
      lz77_copy(<<output:bits, byte>>, distance, count - 1, pos + 1)
    }
  }
}

/// Emit `count` literals decoded one by one from the literal prefix
/// code.  Honours the metablock's `remaining` budget.
fn emit_literals(
  reader: Reader,
  state: CommandState,
  count: Int,
) -> Result(#(CommandState, Reader), error.CodecError) {
  let actual = int.min(count, state.remaining)
  emit_literals_loop(reader, state, actual)
}

fn emit_literals_loop(
  reader: Reader,
  state: CommandState,
  remaining: Int,
) -> Result(#(CommandState, Reader), error.CodecError) {
  case remaining {
    0 -> Ok(#(state, reader))
    _ -> {
      let tree =
        pick_tree_by_index(state.literal_codes, select_literal_tree_idx(state))
      use #(byte, reader) <- result.try(decode_prefix_symbol(reader, tree))
      let projected = bit_array.byte_size(state.output) + 1
      use <- bool.guard(
        when: projected > limit.max_output_bytes(state.limits),
        return: Error(error.CodecLimitExceeded(
          limit: "max_output_bytes",
          value: projected,
        )),
      )
      let new_state =
        CommandState(
          ..state,
          output: <<state.output:bits, byte>>,
          remaining: state.remaining - 1,
          prev2: state.prev1,
          prev1: byte,
        )
      emit_literals_loop(reader, new_state, remaining - 1)
    }
  }
}

// -- Context-driven tree selection (RFC 7932 §7.3) ---------------------

fn select_literal_tree_idx(state: CommandState) -> Int {
  let context_mode = case state.context_modes {
    [m, ..] -> m
    [] -> 0
  }
  let ctx = brotli_ctx.context_id(context_mode, state.prev1, state.prev2)
  // block_type_l = 0 since NBLTYPES_L = 1.
  case bit_array.byte_size(state.literal_context_map) {
    0 -> 0
    _ -> byte_at_or_zero(state.literal_context_map, ctx)
  }
}

fn select_distance_tree_idx(state: CommandState, distance_context: Int) -> Int {
  // block_type_d = 0 since NBLTYPES_D = 1.
  case bit_array.byte_size(state.distance_context_map) {
    0 -> 0
    _ -> byte_at_or_zero(state.distance_context_map, distance_context)
  }
}

fn pick_tree_by_index(trees: List(PrefixCode), idx: Int) -> PrefixCode {
  case trees, idx {
    [head, ..], 0 -> head
    [_, ..tail], _ -> pick_tree_by_index(tail, idx - 1)
    [], _ -> {
      let assert [head, ..] = trees
      head
    }
  }
}

// -- Update copy bookkeeping with `prev1`/`prev2` from the tail of the
//    copy or dictionary insert.  Called by `in_window_copy` and
//    `dictionary_copy` after the output buffer has grown.

fn refresh_prev_bytes(state: CommandState) -> CommandState {
  let pos = bit_array.byte_size(state.output)
  CommandState(
    ..state,
    prev1: byte_at_or_zero(state.output, pos - 1),
    prev2: byte_at_or_zero(state.output, pos - 2),
  )
}

// -- Insert-and-copy alphabet (RFC 7932 §5 / brotli `kCmdLut`) ---------

type Command {
  Command(
    insert_len: Int,
    copy_len: Int,
    /// `-1` for "no distance code follows; reuse most recent
    /// distance"; `0` for "decode a distance code".  Mirrors brotli's
    /// `kCmdLut[code].distance_code` field.
    distance_code: Int,
    distance_context: Int,
  )
}

fn decode_command(
  reader: Reader,
  code: PrefixCode,
) -> Result(#(Command, Reader), error.CodecError) {
  use #(symbol, reader) <- result.try(decode_prefix_symbol(reader, code))
  let lut = cmd_lut_entry(symbol)
  use #(ins_extra, reader) <- result.try(read_bits(reader, lut.ins_extra_bits))
  use #(copy_extra, reader) <- result.try(read_bits(reader, lut.copy_extra_bits))
  let command =
    Command(
      insert_len: lut.ins_offset + ins_extra,
      copy_len: lut.copy_offset + copy_extra,
      distance_code: lut.distance_code,
      distance_context: lut.context,
    )
  Ok(#(command, reader))
}

type CmdLut {
  CmdLut(
    ins_extra_bits: Int,
    copy_extra_bits: Int,
    distance_code: Int,
    context: Int,
    ins_offset: Int,
    copy_offset: Int,
  )
}

/// Compute the `kCmdLut`-equivalent entry for an insert-and-copy
/// symbol (0..703).  Algorithm matches `BrotliDecoderInitCmdLut` in
/// `brotli/c/dec/prefix.c`:
///
///   cell_idx = symbol >> 6
///   cell_pos = kCellPos[cell_idx]
///   copy_code   = ((cell_pos << 3) & 0x18) | (symbol & 0x7)
///   insert_code = (cell_pos & 0x18) | ((symbol >> 3) & 0x7)
///
/// distance_code = -1 for cell_idx ≥ 2 (literal-and-copy with reused
/// distance), 0 otherwise.  context = 3 when copy_offset > 4, else
/// copy_offset - 2.
fn cmd_lut_entry(symbol: Int) -> CmdLut {
  let cell_idx = int.bitwise_shift_right(symbol, 6)
  let cell_pos = cell_pos_table(cell_idx)
  let copy_code =
    int.bitwise_or(
      int.bitwise_and(int.bitwise_shift_left(cell_pos, 3), 0x18),
      int.bitwise_and(symbol, 0x7),
    )
  let insert_code =
    int.bitwise_or(
      int.bitwise_and(cell_pos, 0x18),
      int.bitwise_and(int.bitwise_shift_right(symbol, 3), 0x7),
    )
  let copy_off = cumulative_copy_offset(copy_code)
  let dist_code = case cell_idx >= 2 {
    True -> -1
    False -> 0
  }
  let context = case copy_off > 4 {
    True -> 3
    False -> copy_off - 2
  }
  CmdLut(
    ins_extra_bits: insert_extra_bits(insert_code),
    copy_extra_bits: copy_extra_bits(copy_code),
    distance_code: dist_code,
    context: context,
    ins_offset: cumulative_insert_offset(insert_code),
    copy_offset: copy_off,
  )
}

fn cell_pos_table(idx: Int) -> Int {
  case idx {
    0 -> 0
    1 -> 1
    2 -> 0
    3 -> 1
    4 -> 8
    5 -> 9
    6 -> 2
    7 -> 16
    8 -> 10
    9 -> 17
    _ -> 18
  }
}

fn insert_extra_bits(code: Int) -> Int {
  case code {
    0 | 1 | 2 | 3 | 4 | 5 -> 0
    6 | 7 -> 1
    8 | 9 -> 2
    10 | 11 -> 3
    12 | 13 -> 4
    14 | 15 -> 5
    16 -> 6
    17 -> 7
    18 -> 8
    19 -> 9
    20 -> 10
    21 -> 12
    22 -> 14
    _ -> 24
  }
}

fn copy_extra_bits(code: Int) -> Int {
  case code {
    0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 -> 0
    8 | 9 -> 1
    10 | 11 -> 2
    12 | 13 -> 3
    14 | 15 -> 4
    16 | 17 -> 5
    18 -> 6
    19 -> 7
    20 -> 8
    21 -> 9
    22 -> 10
    _ -> 24
  }
}

fn cumulative_insert_offset(target: Int) -> Int {
  cumulative_offset_loop(0, 0, target, insert_extra_bits)
}

fn cumulative_copy_offset(target: Int) -> Int {
  cumulative_offset_loop(2, 0, target, copy_extra_bits)
}

fn cumulative_offset_loop(
  cur: Int,
  idx: Int,
  target: Int,
  extra: fn(Int) -> Int,
) -> Int {
  case idx == target {
    True -> cur
    False ->
      cumulative_offset_loop(
        cur + int.bitwise_shift_left(1, extra(idx)),
        idx + 1,
        target,
        extra,
      )
  }
}

fn reject_block_switching(
  category: String,
  count: Int,
) -> Result(Nil, error.CodecError) {
  case count > 1 {
    True ->
      Error(error.CodecNotImplemented(
        feature: "brotli " <> category <> " block switching (NBLTYPES > 1)",
      ))
    False -> Ok(Nil)
  }
}

/// Decode a context map per RFC 7932 §7.3.  When `ntrees == 1` the
/// map is implicitly all zeros and no bits are read.  Otherwise:
///
/// 1. Read 1 bit.  If 1, read 4 more bits to compute `RLEMAX = bits + 1`
///    (range 1..16).  If 0, `RLEMAX = 0`.
/// 2. Read a prefix code for the alphabet of size `ntrees + RLEMAX`.
/// 3. Decode `size` entries:
///    * `code == 0` → emit a 0
///    * `code > RLEMAX` → emit `code - RLEMAX`
///    * `1 <= code <= RLEMAX` → read `code` extra bits; reps
///      = extra + (1 << code); emit that many zeros
/// 4. Read 1 bit.  If 1, apply inverse-move-to-front transform.
fn decode_context_map(
  reader: Reader,
  ntrees: Int,
  size: Int,
) -> Result(#(BitArray, Reader), error.CodecError) {
  case ntrees <= 1 {
    True -> Ok(#(byte_repeat(0, size), reader))
    False -> decode_nontrivial_context_map(reader, ntrees, size)
  }
}

fn decode_nontrivial_context_map(
  reader: Reader,
  ntrees: Int,
  size: Int,
) -> Result(#(BitArray, Reader), error.CodecError) {
  use #(use_rle, reader) <- result.try(read_bits(reader, 1))
  use #(rlemax, reader) <- result.try(case use_rle {
    0 -> Ok(#(0, reader))
    _ -> {
      use #(extra, reader) <- result.try(read_bits(reader, 4))
      Ok(#(extra + 1, reader))
    }
  })
  let alphabet_size = ntrees + rlemax
  use #(code, reader) <- result.try(decode_prefix_code(
    reader,
    alphabet_size,
    "context-map",
  ))
  use #(entries, reader) <- result.try(
    decode_context_map_entries(reader, code, rlemax, size, []),
  )
  use #(imtf_flag, reader) <- result.try(read_bits(reader, 1))
  let entries = case imtf_flag {
    0 -> entries
    _ -> imtf(entries)
  }
  Ok(#(bytes_from_int_list(entries), reader))
}

fn decode_context_map_entries(
  reader: Reader,
  code: PrefixCode,
  rlemax: Int,
  remaining: Int,
  acc: List(Int),
) -> Result(#(List(Int), Reader), error.CodecError) {
  case remaining {
    n if n <= 0 -> Ok(#(list.reverse(acc), reader))
    _ -> step_context_map_entry(reader, code, rlemax, remaining, acc)
  }
}

fn step_context_map_entry(
  reader: Reader,
  code: PrefixCode,
  rlemax: Int,
  remaining: Int,
  acc: List(Int),
) -> Result(#(List(Int), Reader), error.CodecError) {
  use #(symbol, reader) <- result.try(decode_prefix_symbol(reader, code))
  case symbol == 0 || symbol > rlemax {
    True -> {
      let value = symbol_to_value(symbol, rlemax)
      decode_context_map_entries(reader, code, rlemax, remaining - 1, [
        value,
        ..acc
      ])
    }
    False -> {
      // 1 ≤ symbol ≤ rlemax: zero-run.
      use #(extra, reader) <- result.try(read_bits(reader, symbol))
      let reps = extra + int.bitwise_shift_left(1, symbol)
      use <- bool.guard(
        when: reps > remaining,
        return: Error(error.CodecInvalidData(
          message: "brotli context-map zero run overruns map size",
        )),
      )
      decode_context_map_entries(
        reader,
        code,
        rlemax,
        remaining - reps,
        prepend_zeros(reps, acc),
      )
    }
  }
}

fn symbol_to_value(symbol: Int, rlemax: Int) -> Int {
  case symbol {
    0 -> 0
    _ -> symbol - rlemax
  }
}

fn prepend_zeros(n: Int, acc: List(Int)) -> List(Int) {
  case n {
    0 -> acc
    _ -> prepend_zeros(n - 1, [0, ..acc])
  }
}

fn bytes_from_int_list(values: List(Int)) -> BitArray {
  list.fold(values, <<>>, fn(acc, v) { <<acc:bits, v>> })
}

fn byte_repeat(byte: Int, count: Int) -> BitArray {
  byte_repeat_loop(byte, count, <<>>)
}

fn byte_repeat_loop(byte: Int, count: Int, acc: BitArray) -> BitArray {
  case count {
    n if n <= 0 -> acc
    _ -> byte_repeat_loop(byte, count - 1, <<acc:bits, byte>>)
  }
}

// -- Inverse Move-to-Front transform (RFC 7932 §7.3) -------------------

/// Apply IMTF to a list of byte indices.  Initial table is [0..255].
/// For each index `i`: emit `table[i]`, then move that value to the
/// front (shifting earlier entries one place back).
fn imtf(input: List(Int)) -> List(Int) {
  imtf_loop(input, init_mtf(255, []), [])
}

fn init_mtf(n: Int, acc: List(Int)) -> List(Int) {
  case n < 0 {
    True -> acc
    False -> init_mtf(n - 1, [n, ..acc])
  }
}

fn imtf_loop(input: List(Int), table: List(Int), output: List(Int)) -> List(Int) {
  case input {
    [] -> list.reverse(output)
    [idx, ..rest] -> {
      let value = mtf_value_at(table, idx)
      let new_table = [value, ..list.filter(table, fn(v) { v != value })]
      imtf_loop(rest, new_table, [value, ..output])
    }
  }
}

fn mtf_value_at(table: List(Int), idx: Int) -> Int {
  case table, idx {
    [head, ..], 0 -> head
    [_, ..tail], _ -> mtf_value_at(tail, idx - 1)
    [], _ -> 0
  }
}

// -- Prefix code descriptors (RFC 7932 §3.4) ---------------------------

/// A decoded prefix code: each entry pairs a symbol with its canonical
/// MSB-first code value and bit length.  A length of 0 marks the
/// degenerate one-symbol code that consumes no bits.
type PrefixCode {
  PrefixCode(entries: List(PrefixEntry))
}

type PrefixEntry {
  PrefixEntry(symbol: Int, length: Int, code: Int)
}

fn decode_prefix_codes(
  reader: Reader,
  remaining: Int,
  alphabet_size: Int,
  kind: String,
  acc: List(PrefixCode),
) -> Result(#(List(PrefixCode), Reader), error.CodecError) {
  case remaining {
    0 -> Ok(#(list.reverse(acc), reader))
    _ -> {
      use #(code, reader) <- result.try(decode_prefix_code(
        reader,
        alphabet_size,
        kind,
      ))
      decode_prefix_codes(reader, remaining - 1, alphabet_size, kind, [
        code,
        ..acc
      ])
    }
  }
}

fn decode_prefix_code(
  reader: Reader,
  alphabet_size: Int,
  _kind: String,
) -> Result(#(PrefixCode, Reader), error.CodecError) {
  use #(descriptor, reader) <- result.try(read_bits(reader, 2))
  case descriptor {
    1 -> decode_simple_prefix_code(reader, alphabet_size)
    // 0, 2, 3 → complex form (HSKIP = descriptor, RFC 7932 §3.5).
    hskip -> decode_complex_prefix_code(reader, alphabet_size, hskip)
  }
}

fn decode_simple_prefix_code(
  reader: Reader,
  alphabet_size: Int,
) -> Result(#(PrefixCode, Reader), error.CodecError) {
  use #(nsym_minus_1, reader) <- result.try(read_bits(reader, 2))
  let nsym = nsym_minus_1 + 1
  let alphabet_bits = ceil_log2(alphabet_size)
  use #(symbols, reader) <- result.try(
    read_simple_symbols(reader, nsym, alphabet_bits, []),
  )
  use _ <- result.try(check_alphabet_bounds(symbols, alphabet_size))
  use _ <- result.try(check_no_duplicates(symbols))
  build_simple_layout(reader, nsym, symbols)
}

fn build_simple_layout(
  reader: Reader,
  nsym: Int,
  symbols: List(Int),
) -> Result(#(PrefixCode, Reader), error.CodecError) {
  case nsym {
    1 -> Ok(#(canonicalise(symbols, [0]), reader))
    2 -> Ok(#(canonicalise(sort_asc(symbols), [1, 1]), reader))
    3 -> {
      // RFC 7932 §3.4: the first symbol keeps its position and gets a
      // length-1 code; the remaining two are sorted ascending and get
      // length-2 codes.
      let assert [first, ..rest] = symbols
      let sorted_rest = sort_asc(rest)
      Ok(#(canonicalise([first, ..sorted_rest], [1, 2, 2]), reader))
    }
    _ -> {
      use #(tree_select, reader) <- result.try(read_bits(reader, 1))
      case tree_select {
        0 -> Ok(#(canonicalise(sort_asc(symbols), [2, 2, 2, 2]), reader))
        _ -> {
          let assert [first, ..rest] = symbols
          let sorted_rest = sort_asc(rest)
          Ok(#(canonicalise([first, ..sorted_rest], [1, 2, 3, 3]), reader))
        }
      }
    }
  }
}

/// Build a canonical-Huffman `PrefixCode` from a parallel list of
/// symbols and code-lengths.  Walks `(symbol, length)` pairs in
/// length-ascending order, assigning MSB-first code values via the
/// standard canonical-Huffman recurrence.
fn canonicalise(symbols: List(Int), lengths: List(Int)) -> PrefixCode {
  let pairs = list.zip(symbols, lengths)
  let sorted =
    list.sort(pairs, fn(a, b) {
      let #(_, len_a) = a
      let #(_, len_b) = b
      int.compare(len_a, len_b)
    })
  PrefixCode(entries: assign_canonical(sorted, 0, 0, []))
}

fn assign_canonical(
  pairs: List(#(Int, Int)),
  next_code: Int,
  prev_length: Int,
  acc: List(PrefixEntry),
) -> List(PrefixEntry) {
  case pairs {
    [] -> list.reverse(acc)
    [#(sym, len), ..rest] -> {
      let shifted = int.bitwise_shift_left(next_code, len - prev_length)
      assign_canonical(rest, shifted + 1, len, [
        PrefixEntry(symbol: sym, length: len, code: shifted),
        ..acc
      ])
    }
  }
}

/// Build a `PrefixCode` from `(symbol, length)` pairs where a length
/// of 0 indicates the symbol is absent from the code.  Sorts the
/// remaining pairs by `(length asc, symbol asc)` and applies the
/// canonical-Huffman recurrence.  Collapses the degenerate single-
/// active-symbol case to length 0 to match RFC 7932 §3.5.
fn canonicalise_from_pairs(pairs: List(#(Int, Int))) -> PrefixCode {
  let active =
    list.filter(pairs, fn(p) {
      let #(_, len) = p
      len > 0
    })
  case active {
    [#(sym, _)] ->
      PrefixCode(entries: [PrefixEntry(symbol: sym, length: 0, code: 0)])
    _ -> {
      let by_sym =
        list.sort(active, fn(a, b) {
          let #(sa, _) = a
          let #(sb, _) = b
          int.compare(sa, sb)
        })
      let by_len =
        list.sort(by_sym, fn(a, b) {
          let #(_, la) = a
          let #(_, lb) = b
          int.compare(la, lb)
        })
      PrefixCode(entries: assign_canonical(by_len, 0, 0, []))
    }
  }
}

// -- Complex-form prefix codes (RFC 7932 §3.5) -------------------------
//
// The encoding is two-stage: first the lengths of an 18-symbol code
// (covering literal code lengths 0..15 plus repeat-prev=16 and
// repeat-zero=17) are read using a fixed 16-entry lookup table; then
// those lengths build a Huffman "CL" code which itself decodes the
// final alphabet's code lengths, with the 16/17 repeats expanding
// runs of the previous (non-zero or zero) length.

/// Read order for the 18 code-length-code-lengths.  HSKIP entries are
/// implicitly zero; the remainder is read in this order until either
/// all are consumed or the Huffman space (32) is exhausted.
fn cl_code_order() -> List(Int) {
  [1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15]
}

/// Lookup tables for the fixed 4-bit code that encodes each CL
/// code-length value.  Indexed by a 4-bit peek; returns
/// `#(bits_to_consume, value)`.  Values are in 0..5 — never 6..15 —
/// since CL code-lengths can't exceed 5 bits.  Mirrors the brotli C
/// reference `kCodeLengthPrefixLength` + `kCodeLengthPrefixValue`.
fn cl_prefix_lookup(ix: Int) -> #(Int, Int) {
  case ix {
    0 -> #(2, 0)
    1 -> #(2, 4)
    2 -> #(2, 3)
    3 -> #(3, 2)
    4 -> #(2, 0)
    5 -> #(2, 4)
    6 -> #(2, 3)
    7 -> #(4, 1)
    8 -> #(2, 0)
    9 -> #(2, 4)
    10 -> #(2, 3)
    11 -> #(3, 2)
    12 -> #(2, 0)
    13 -> #(2, 4)
    14 -> #(2, 3)
    _ -> #(4, 5)
  }
}

fn decode_complex_prefix_code(
  reader: Reader,
  alphabet_size: Int,
  hskip: Int,
) -> Result(#(PrefixCode, Reader), error.CodecError) {
  let order = list.drop(cl_code_order(), hskip)
  use #(cl_pairs, reader) <- result.try(
    read_cl_code_lengths(reader, order, 32, 0, []),
  )
  let cl_code = canonicalise_from_pairs(cl_pairs)
  use #(symbol_pairs, reader) <- result.try(
    read_symbol_code_lengths(
      reader,
      cl_code,
      alphabet_size,
      SymLenState(symbol: 0, space: 32_768, prev: 8, repeat: 0, repeat_len: 0),
      [],
    ),
  )
  Ok(#(canonicalise_from_pairs(symbol_pairs), reader))
}

fn read_cl_code_lengths(
  reader: Reader,
  remaining_order: List(Int),
  space: Int,
  num_codes: Int,
  accum: List(#(Int, Int)),
) -> Result(#(List(#(Int, Int)), Reader), error.CodecError) {
  case remaining_order {
    [] -> validate_cl_space(num_codes, space, accum, reader)
    [cl_sym, ..rest] ->
      read_one_cl(reader, cl_sym, rest, space, num_codes, accum)
  }
}

fn read_one_cl(
  reader: Reader,
  cl_sym: Int,
  rest: List(Int),
  space: Int,
  num_codes: Int,
  accum: List(#(Int, Int)),
) -> Result(#(List(#(Int, Int)), Reader), error.CodecError) {
  use reader <- result.try(ensure_bits(reader, 4))
  let ix = peek_bits_value(reader, 4)
  let #(consume, value) = cl_prefix_lookup(ix)
  let reader = drop_bits(reader, consume)
  let new_accum = [#(cl_sym, value), ..accum]
  case value {
    0 -> read_cl_code_lengths(reader, rest, space, num_codes, new_accum)
    _ -> {
      let new_space = space - int.bitwise_shift_right(32, value)
      let new_num = num_codes + 1
      case new_space <= 0 {
        True -> validate_cl_space(new_num, new_space, new_accum, reader)
        False ->
          read_cl_code_lengths(reader, rest, new_space, new_num, new_accum)
      }
    }
  }
}

fn validate_cl_space(
  num_codes: Int,
  space: Int,
  accum: List(#(Int, Int)),
  reader: Reader,
) -> Result(#(List(#(Int, Int)), Reader), error.CodecError) {
  use <- bool.guard(
    when: space < 0,
    return: Error(error.CodecInvalidData(
      message: "brotli code-length codes oversubscribe Huffman space",
    )),
  )
  case num_codes == 1 || space == 0 {
    True -> {
      Ok(#(accum, reader))
    }
    False ->
      Error(error.CodecInvalidData(
        message: "brotli code-length codes underfill Huffman space",
      ))
  }
}

type SymLenState {
  SymLenState(symbol: Int, space: Int, prev: Int, repeat: Int, repeat_len: Int)
}

fn read_symbol_code_lengths(
  reader: Reader,
  cl_code: PrefixCode,
  alphabet_size: Int,
  state: SymLenState,
  accum: List(#(Int, Int)),
) -> Result(#(List(#(Int, Int)), Reader), error.CodecError) {
  case state.symbol >= alphabet_size || state.space <= 0 {
    True -> finalize_symbol_lengths(reader, state, accum)
    False -> step_symbol_length(reader, cl_code, alphabet_size, state, accum)
  }
}

fn finalize_symbol_lengths(
  reader: Reader,
  state: SymLenState,
  accum: List(#(Int, Int)),
) -> Result(#(List(#(Int, Int)), Reader), error.CodecError) {
  use <- bool.guard(
    when: state.space != 0,
    return: Error(error.CodecInvalidData(
      message: "brotli symbol code lengths do not fully consume Huffman space",
    )),
  )
  Ok(#(accum, reader))
}

fn step_symbol_length(
  reader: Reader,
  cl_code: PrefixCode,
  alphabet_size: Int,
  state: SymLenState,
  accum: List(#(Int, Int)),
) -> Result(#(List(#(Int, Int)), Reader), error.CodecError) {
  use #(code_len, reader) <- result.try(decode_prefix_symbol(reader, cl_code))
  case code_len < 16 {
    True ->
      apply_single_code_length(
        reader,
        cl_code,
        alphabet_size,
        state,
        accum,
        code_len,
      )
    False ->
      apply_repeat_code_length(
        reader,
        cl_code,
        alphabet_size,
        state,
        accum,
        code_len,
      )
  }
}

fn apply_single_code_length(
  reader: Reader,
  cl_code: PrefixCode,
  alphabet_size: Int,
  state: SymLenState,
  accum: List(#(Int, Int)),
  code_len: Int,
) -> Result(#(List(#(Int, Int)), Reader), error.CodecError) {
  let new_accum = case code_len {
    0 -> accum
    _ -> [#(state.symbol, code_len), ..accum]
  }
  let new_space = case code_len {
    0 -> state.space
    _ -> state.space - int.bitwise_shift_right(32_768, code_len)
  }
  let new_prev = case code_len {
    0 -> state.prev
    _ -> code_len
  }
  let new_state =
    SymLenState(
      symbol: state.symbol + 1,
      space: new_space,
      prev: new_prev,
      repeat: 0,
      repeat_len: 0,
    )
  read_symbol_code_lengths(reader, cl_code, alphabet_size, new_state, new_accum)
}

fn apply_repeat_code_length(
  reader: Reader,
  cl_code: PrefixCode,
  alphabet_size: Int,
  state: SymLenState,
  accum: List(#(Int, Int)),
  code_len: Int,
) -> Result(#(List(#(Int, Int)), Reader), error.CodecError) {
  let #(new_len, extra_bits) = case code_len {
    16 -> #(state.prev, 2)
    _ -> #(0, 3)
  }
  use #(extra, reader) <- result.try(read_bits(reader, extra_bits))
  let prior_repeat = case state.repeat_len == new_len {
    True -> state.repeat
    False -> 0
  }
  let scaled = case prior_repeat > 0 {
    True -> int.bitwise_shift_left(prior_repeat - 2, extra_bits)
    False -> 0
  }
  let new_repeat = scaled + extra + 3
  let delta = new_repeat - prior_repeat
  use <- bool.guard(
    when: state.symbol + delta > alphabet_size,
    return: Error(error.CodecInvalidData(
      message: "brotli repeat code overruns alphabet",
    )),
  )
  let #(new_accum, new_space) = case new_len {
    0 -> #(accum, state.space)
    _ -> #(
      prepend_repeated(state.symbol, delta, new_len, accum),
      state.space - int.bitwise_shift_left(delta, 15 - new_len),
    )
  }
  let new_state =
    SymLenState(
      symbol: state.symbol + delta,
      space: new_space,
      prev: state.prev,
      repeat: new_repeat,
      repeat_len: new_len,
    )
  read_symbol_code_lengths(reader, cl_code, alphabet_size, new_state, new_accum)
}

fn prepend_repeated(
  start: Int,
  delta: Int,
  length: Int,
  acc: List(#(Int, Int)),
) -> List(#(Int, Int)) {
  case delta {
    0 -> acc
    _ ->
      prepend_repeated(start + 1, delta - 1, length, [#(start, length), ..acc])
  }
}

fn decode_prefix_symbol(
  reader: Reader,
  code: PrefixCode,
) -> Result(#(Int, Reader), error.CodecError) {
  decode_prefix_walk(reader, code.entries, 0, 0)
}

fn decode_prefix_walk(
  reader: Reader,
  entries: List(PrefixEntry),
  accumulated: Int,
  bit_count: Int,
) -> Result(#(Int, Reader), error.CodecError) {
  case find_prefix_entry(entries, bit_count, accumulated) {
    Ok(symbol) -> Ok(#(symbol, reader))
    Error(_) -> {
      use #(bit, reader) <- result.try(read_bits(reader, 1))
      let new_acc = int.bitwise_shift_left(accumulated, 1) + bit
      decode_prefix_walk(reader, entries, new_acc, bit_count + 1)
    }
  }
}

fn find_prefix_entry(
  entries: List(PrefixEntry),
  length: Int,
  value: Int,
) -> Result(Int, Nil) {
  case entries {
    [] -> Error(Nil)
    [entry, ..rest] ->
      case entry.length == length && entry.code == value {
        True -> Ok(entry.symbol)
        False -> find_prefix_entry(rest, length, value)
      }
  }
}

fn ceil_log2(n: Int) -> Int {
  ceil_log2_loop(n, 0, 1)
}

fn ceil_log2_loop(target: Int, k: Int, pow: Int) -> Int {
  case pow >= target {
    True -> k
    False -> ceil_log2_loop(target, k + 1, pow * 2)
  }
}

fn read_simple_symbols(
  reader: Reader,
  remaining: Int,
  bits_per: Int,
  acc: List(Int),
) -> Result(#(List(Int), Reader), error.CodecError) {
  case remaining {
    0 -> Ok(#(list.reverse(acc), reader))
    _ -> {
      use #(sym, reader) <- result.try(read_bits(reader, bits_per))
      read_simple_symbols(reader, remaining - 1, bits_per, [sym, ..acc])
    }
  }
}

fn sort_asc(symbols: List(Int)) -> List(Int) {
  list.sort(symbols, int.compare)
}

fn check_no_duplicates(symbols: List(Int)) -> Result(Nil, error.CodecError) {
  case has_consecutive_dup(sort_asc(symbols)) {
    True ->
      Error(error.CodecInvalidData(
        message: "brotli simple-form prefix code has duplicate symbols",
      ))
    False -> Ok(Nil)
  }
}

fn has_consecutive_dup(sorted: List(Int)) -> Bool {
  case sorted {
    [] -> False
    [_] -> False
    [a, b, ..] if a == b -> True
    [_, ..rest] -> has_consecutive_dup(rest)
  }
}

fn check_alphabet_bounds(
  symbols: List(Int),
  alphabet_size: Int,
) -> Result(Nil, error.CodecError) {
  case list.any(symbols, fn(s) { s >= alphabet_size }) {
    True ->
      Error(error.CodecInvalidData(
        message: "brotli simple-form prefix code symbol exceeds alphabet size",
      ))
    False -> Ok(Nil)
  }
}

fn read_context_modes(
  reader: Reader,
  remaining: Int,
  acc: List(Int),
) -> Result(#(List(Int), Reader), error.CodecError) {
  case remaining {
    0 -> Ok(#(list.reverse(acc), reader))
    _ -> {
      use #(mode, reader) <- result.try(read_bits(reader, 2))
      read_context_modes(reader, remaining - 1, [mode, ..acc])
    }
  }
}

// -- RFC 7932 §9.2 variable-length 8-bit integer -----------------------
//
// Encodes a number in 0..255 using 1–11 bits.  Used for NBLTYPES,
// NTREES, and other small population counts.
fn decode_var_len_uint8(
  reader: Reader,
) -> Result(#(Int, Reader), error.CodecError) {
  use #(first, reader) <- result.try(read_bits(reader, 1))
  case first {
    0 -> Ok(#(1, reader))
    _ -> {
      use #(triple, reader) <- result.try(read_bits(reader, 3))
      case triple {
        0 -> Ok(#(2, reader))
        n -> {
          use #(extra, reader) <- result.try(read_bits(reader, n))
          let base = int.bitwise_shift_left(1, n)
          Ok(#(base + extra + 1, reader))
        }
      }
    }
  }
}

fn decode_skip_metablock(
  reader: Reader,
  output: BitArray,
  ring: DistRing,
) -> Result(#(BitArray, DistRing, Reader), error.CodecError) {
  use #(reserved, reader) <- result.try(read_bits(reader, 1))
  use <- bool.guard(
    when: reserved != 0,
    return: Error(error.CodecInvalidData(
      message: "brotli skip metablock reserved bit must be zero",
    )),
  )
  use #(mskipbytes, reader) <- result.try(read_bits(reader, 2))
  use #(mskiplen, reader) <- result.try(case mskipbytes {
    0 -> Ok(#(0, reader))
    n -> read_bits(reader, n * 8)
  })
  let skip = mskiplen + 1
  let reader = align_to_byte(reader)
  let reader = consume_bytes(reader, skip)
  Ok(#(output, ring, reader))
}

fn decode_uncompressed_metablock(
  reader: Reader,
  output: BitArray,
  ring: DistRing,
  mlen: Int,
  limits: limit.Limits,
) -> Result(#(BitArray, DistRing, Reader), error.CodecError) {
  let reader = align_to_byte(reader)
  use #(chunk, reader) <- result.try(take_bytes(reader, mlen))
  let projected = bit_array.byte_size(output) + bit_array.byte_size(chunk)
  case projected > limit.max_output_bytes(limits) {
    True ->
      Error(error.CodecLimitExceeded(
        limit: "max_output_bytes",
        value: projected,
      ))
    False -> Ok(#(bit_array.concat([output, chunk]), ring, reader))
  }
}

// -- WBITS prefix ------------------------------------------------------

/// Read the WBITS prefix per RFC 7932 §9.1.  The encoding is:
///
/// * `0` → 16
/// * `1nnn` where `nnn ≠ 000` → 17 + nnn (range 18..24)
/// * `1000 nnn` where `nnn ≠ 000` and `nnn ≠ 001` → 8 + nnn (range 10..15)
/// * `1000 000` → 17
/// * `1000 001` → reserved / large-window indicator (not supported)
fn read_wbits(reader: Reader) -> Result(#(Int, Reader), error.CodecError) {
  use #(first, reader) <- result.try(read_bits(reader, 1))
  case first {
    0 -> Ok(#(16, reader))
    _ -> read_wbits_after_lead(reader)
  }
}

fn read_wbits_after_lead(
  reader: Reader,
) -> Result(#(Int, Reader), error.CodecError) {
  use #(triple, reader) <- result.try(read_bits(reader, 3))
  case triple {
    0 -> read_wbits_short_range(reader)
    n -> Ok(#(17 + n, reader))
  }
}

fn read_wbits_short_range(
  reader: Reader,
) -> Result(#(Int, Reader), error.CodecError) {
  use #(extra, reader) <- result.try(read_bits(reader, 3))
  case extra {
    0 -> Ok(#(17, reader))
    1 ->
      Error(error.CodecInvalidData(
        message: "brotli large-window WBITS prefix is not supported",
      ))
    n -> Ok(#(8 + n, reader))
  }
}

// -- LSB-first bit reader (with byte-aligned tail access) ---------------

type Reader {
  Reader(source: BitArray, buffer: Int, bits: Int, overflow: Bool)
}

fn new_reader(source: BitArray) -> Reader {
  Reader(source: source, buffer: 0, bits: 0, overflow: False)
}

fn refill(reader: Reader, needed: Int) -> Reader {
  case reader.bits >= needed || reader.overflow {
    True -> reader
    False ->
      case reader.source {
        <<b, rest:bytes>> ->
          refill(
            Reader(
              source: rest,
              buffer: int.bitwise_or(
                reader.buffer,
                int.bitwise_shift_left(b, reader.bits),
              ),
              bits: reader.bits + 8,
              overflow: False,
            ),
            needed,
          )
        _ ->
          Reader(
            source: <<>>,
            buffer: reader.buffer,
            bits: reader.bits,
            overflow: True,
          )
      }
  }
}

fn read_bits(
  reader: Reader,
  count: Int,
) -> Result(#(Int, Reader), error.CodecError) {
  case count {
    0 -> Ok(#(0, reader))
    _ -> {
      use reader <- result.try(ensure_bits(reader, count))
      let value = peek_bits_value(reader, count)
      Ok(#(value, drop_bits(reader, count)))
    }
  }
}

/// Refill the bit buffer until it holds at least `count` bits; error
/// out if the source stream is shorter than that.  Used by both
/// `read_bits` and the peek/drop API the complex-form prefix code
/// reader needs (to look up a variable-length CL code by 4-bit peek).
fn ensure_bits(reader: Reader, count: Int) -> Result(Reader, error.CodecError) {
  let reader = refill(reader, count)
  case reader.bits >= count {
    True -> Ok(reader)
    False ->
      Error(error.CodecInvalidData(message: "truncated brotli bit stream"))
  }
}

/// LSB-first read of `count` bits without consuming them.  Callers
/// must first call `ensure_bits` to guarantee the buffer is filled.
fn peek_bits_value(reader: Reader, count: Int) -> Int {
  let mask = int.bitwise_shift_left(1, count) - 1
  int.bitwise_and(reader.buffer, mask)
}

/// Consume `count` bits previously inspected with `peek_bits_value`.
fn drop_bits(reader: Reader, count: Int) -> Reader {
  Reader(
    source: reader.source,
    buffer: int.bitwise_shift_right(reader.buffer, count),
    bits: reader.bits - count,
    overflow: reader.overflow,
  )
}

/// Drop the remaining bits in the current byte so the next byte-level
/// operation aligns to a byte boundary.  This matches brotli's
/// `jump_to_byte_boundary` step before an uncompressed-metablock copy
/// or a skip-metablock skip.
fn align_to_byte(reader: Reader) -> Reader {
  let leftover = reader.bits % 8
  case leftover {
    0 -> reader
    _ -> {
      let value = int.bitwise_shift_right(reader.buffer, leftover)
      let bits = reader.bits - leftover
      Reader(
        source: reader.source,
        buffer: value,
        bits: bits,
        overflow: reader.overflow,
      )
    }
  }
}

fn take_bytes(
  reader: Reader,
  count: Int,
) -> Result(#(BitArray, Reader), error.CodecError) {
  // After align_to_byte, reader.bits is a multiple of 8.  Pull entire
  // bytes from the buffer first, then from source.
  let buffered_bytes = reader.bits / 8
  case count <= buffered_bytes {
    True -> {
      let chunk = bits_to_bit_array(reader.buffer, count, <<>>)
      let remaining_bits = reader.bits - count * 8
      let mask = int.bitwise_shift_left(1, remaining_bits) - 1
      let new_buffer =
        int.bitwise_and(int.bitwise_shift_right(reader.buffer, count * 8), mask)
      Ok(#(
        chunk,
        Reader(
          source: reader.source,
          buffer: new_buffer,
          bits: remaining_bits,
          overflow: reader.overflow,
        ),
      ))
    }
    False -> {
      let buffer_chunk = bits_to_bit_array(reader.buffer, buffered_bytes, <<>>)
      let need = count - buffered_bytes
      case bit_array.slice(reader.source, 0, need) {
        Ok(source_chunk) -> {
          let assert Ok(new_source) =
            bit_array.slice(
              reader.source,
              need,
              bit_array.byte_size(reader.source) - need,
            )
          Ok(#(
            bit_array.concat([buffer_chunk, source_chunk]),
            Reader(source: new_source, buffer: 0, bits: 0, overflow: False),
          ))
        }
        Error(_) ->
          Error(error.CodecInvalidData(
            message: "brotli uncompressed metablock body is truncated",
          ))
      }
    }
  }
}

fn consume_bytes(reader: Reader, count: Int) -> Reader {
  case take_bytes(reader, count) {
    Ok(#(_, r)) -> r
    Error(_) -> reader
  }
}

fn bits_to_bit_array(buffer: Int, count: Int, acc: BitArray) -> BitArray {
  case count {
    0 -> acc
    _ ->
      bits_to_bit_array(int.bitwise_shift_right(buffer, 8), count - 1, <<
        acc:bits,
        int.bitwise_and(buffer, 0xFF),
      >>)
  }
}
