//// Unix `compress(1)` LZW codec — `.Z` stream encoder and decoder.
////
//// The stream begins with the two-byte magic `1F 9D` followed by a
//// flag byte whose low five bits hold the maximum code width
//// (9..16) and whose top bit toggles block-compress mode.  Codes
//// are packed LSB-first across bytes, the dictionary starts with
//// the 256 byte literals (plus a clear-table marker when block mode
//// is on), and each new entry maps the previous code plus the
//// current character to the next free code.  When the dictionary
//// fills the current width, the encoder pads to the next
//// `width * 8` bit boundary before promoting to the next width or
//// emitting a clear-table code.

import gleam/bit_array
import gleam/bool
import gleam/dict
import gleam/int
import gleam/result
import packkit/codec as codecs
import packkit/error
import packkit/limit

const magic_byte_1: Int = 0x1F

const magic_byte_2: Int = 0x9D

const init_bits: Int = 9

const max_bits_max: Int = 16

const clear_code: Int = 256

const default_max_bits: Int = 16

/// LZW codec smart constructor (Unix `.Z` family).
pub fn codec() -> codecs.Codec {
  codecs.lzw()
}

/// Encode `bytes` as a `.Z` stream using the default 16-bit
/// block-mode encoder.
pub fn encode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  encode_with_options(
    bytes: bytes,
    max_bits: default_max_bits,
    block_mode: True,
  )
}

/// Encode `bytes` as a `.Z` stream with explicit options.
pub fn encode_with_options(
  bytes bytes: BitArray,
  max_bits max_bits: Int,
  block_mode block_mode: Bool,
) -> Result(BitArray, error.CodecError) {
  use <- bool.guard(
    when: max_bits < init_bits || max_bits > max_bits_max,
    return: Error(error.CodecInvalidData(
      message: "lzw max_bits out of range (9..16)",
    )),
  )
  let header = build_header(max_bits, block_mode)
  let first_free = case block_mode {
    True -> 257
    False -> 256
  }
  let payload = encode_payload(bytes, max_bits, block_mode, first_free)
  Ok(bit_array.concat([header, payload]))
}

/// Decode a `.Z` stream using the shared default `Limits`.
pub fn decode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  decode_with_limits(bytes: bytes, limits: limit.default())
}

/// Decode a `.Z` stream using explicit `Limits`.
pub fn decode_with_limits(
  bytes bytes: BitArray,
  limits limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  use <- bool.guard(
    when: bit_array.byte_size(bytes) > limit.max_input_bytes(limits),
    return: Error(error.CodecLimitExceeded(
      limit: "max_input_bytes",
      actual: bit_array.byte_size(bytes),
    )),
  )

  case bytes {
    <<m1, m2, flag, rest:bytes>> if m1 == magic_byte_1 && m2 == magic_byte_2 -> {
      let max_bits = int.bitwise_and(flag, 0x1F)
      let block_mode = int.bitwise_and(flag, 0x80) != 0
      use <- bool.guard(
        when: max_bits < init_bits || max_bits > max_bits_max,
        return: Error(error.CodecInvalidData(
          message: "lzw header advertises invalid max_bits",
        )),
      )
      decode_payload(rest, max_bits, block_mode, limits)
    }
    _ ->
      Error(error.CodecInvalidData(message: "lzw stream missing 1F 9D magic"))
  }
}

fn build_header(max_bits: Int, block_mode: Bool) -> BitArray {
  let flag = case block_mode {
    True -> int.bitwise_or(max_bits, 0x80)
    False -> max_bits
  }
  <<magic_byte_1, magic_byte_2, flag>>
}

// -- encoder -------------------------------------------------------------

type EncodeState {
  EncodeState(
    table: dict.Dict(Int, Int),
    prefix: Int,
    free_ent: Int,
    n_bits: Int,
    max_code: Int,
    codes_at_width: Int,
    max_bits: Int,
    block_mode: Bool,
    writer: Writer,
    first_free: Int,
  )
}

fn encode_payload(
  bytes: BitArray,
  max_bits: Int,
  block_mode: Bool,
  first_free: Int,
) -> BitArray {
  case bytes {
    <<first, rest:bytes>> -> {
      let state =
        EncodeState(
          table: dict.new(),
          prefix: first,
          free_ent: first_free,
          n_bits: init_bits,
          max_code: max_code_for(init_bits, max_bits),
          codes_at_width: 0,
          max_bits: max_bits,
          block_mode: block_mode,
          writer: new_writer(),
          first_free: first_free,
        )
      let state = encode_loop(rest, state)
      let writer = write_code_with_padding(state, state.prefix)
      flush_writer(writer)
    }
    _ -> flush_writer(new_writer())
  }
}

fn encode_loop(input: BitArray, state: EncodeState) -> EncodeState {
  case input {
    <<byte, rest:bytes>> -> {
      let key = dictionary_key(state.prefix, byte)
      case dict.get(state.table, key) {
        Ok(code) -> encode_loop(rest, EncodeState(..state, prefix: code))
        Error(_) -> {
          let writer = write_code_with_padding(state, state.prefix)
          let next_state = case state.free_ent <= max_max_code(state.max_bits) {
            True -> {
              let table = dict.insert(state.table, key, state.free_ent)
              promote_width(
                EncodeState(
                  ..state,
                  table: table,
                  free_ent: state.free_ent + 1,
                  writer: writer,
                  codes_at_width: state.codes_at_width + 1,
                  prefix: byte,
                ),
              )
            }
            False ->
              maybe_emit_clear(
                EncodeState(
                  ..state,
                  writer: writer,
                  codes_at_width: state.codes_at_width + 1,
                  prefix: byte,
                ),
              )
          }
          encode_loop(rest, next_state)
        }
      }
    }
    _ -> state
  }
}

fn dictionary_key(prefix: Int, byte: Int) -> Int {
  int.bitwise_or(int.bitwise_shift_left(prefix, 8), byte)
}

fn max_code_for(n_bits: Int, max_bits: Int) -> Int {
  case n_bits >= max_bits {
    True -> max_max_code(max_bits)
    False -> int.bitwise_shift_left(1, n_bits) - 1
  }
}

fn max_max_code(max_bits: Int) -> Int {
  int.bitwise_shift_left(1, max_bits)
}

fn promote_width(state: EncodeState) -> EncodeState {
  case state.free_ent > state.max_code && state.n_bits < state.max_bits {
    True -> {
      let writer = pad_writer_to_block(state.writer, state.n_bits)
      let new_n_bits = state.n_bits + 1
      EncodeState(
        ..state,
        writer: writer,
        n_bits: new_n_bits,
        max_code: max_code_for(new_n_bits, state.max_bits),
        codes_at_width: 0,
      )
    }
    False -> state
  }
}

fn maybe_emit_clear(state: EncodeState) -> EncodeState {
  case state.block_mode && state.free_ent > max_max_code(state.max_bits) {
    True -> {
      let writer = write_code(state.writer, clear_code, state.n_bits)
      let writer = pad_writer_to_block(writer, state.n_bits)
      EncodeState(
        ..state,
        writer: writer,
        free_ent: state.first_free,
        n_bits: init_bits,
        max_code: max_code_for(init_bits, state.max_bits),
        codes_at_width: 0,
        table: dict.new(),
      )
    }
    False -> state
  }
}

fn write_code_with_padding(state: EncodeState, code: Int) -> Writer {
  write_code(state.writer, code, state.n_bits)
}

fn pad_writer_to_block(writer: Writer, n_bits: Int) -> Writer {
  let group_bits = 8 * n_bits
  let leftover = writer.bits_written % group_bits
  case leftover {
    0 -> writer
    _ -> pad_zero_bits(writer, group_bits - leftover)
  }
}

fn pad_zero_bits(writer: Writer, count: Int) -> Writer {
  case count {
    0 -> writer
    n if n >= 32 -> pad_zero_bits(write_bits(writer, 0, 32), n - 32)
    n -> write_bits(writer, 0, n)
  }
}

// -- decoder -------------------------------------------------------------

type DecodeState {
  DecodeState(
    out_rev: List(Int),
    out_len: Int,
    table: dict.Dict(Int, #(Int, Int)),
    free_ent: Int,
    n_bits: Int,
    max_code: Int,
    codes_at_width: Int,
    prev_code: Int,
    has_prev: Bool,
    max_bits: Int,
    block_mode: Bool,
    first_free: Int,
  )
}

fn decode_payload(
  bytes: BitArray,
  max_bits: Int,
  block_mode: Bool,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  let first_free = case block_mode {
    True -> 257
    False -> 256
  }
  let reader = new_reader(bytes)
  let state =
    DecodeState(
      out_rev: [],
      out_len: 0,
      table: dict.new(),
      free_ent: first_free,
      n_bits: init_bits,
      max_code: max_code_for(init_bits, max_bits),
      codes_at_width: 0,
      prev_code: -1,
      has_prev: False,
      max_bits: max_bits,
      block_mode: block_mode,
      first_free: first_free,
    )
  use #(out_rev, out_len) <- result.try(decode_loop(reader, state, limits))
  use _ <- result.try(check_output_limit(out_len, limits))
  Ok(reverse_to_bit_array(out_rev, <<>>))
}

fn decode_loop(
  reader: Reader,
  state: DecodeState,
  limits: limit.Limits,
) -> Result(#(List(Int), Int), error.CodecError) {
  case read_code(reader, state.n_bits) {
    Error(_) -> Ok(#(state.out_rev, state.out_len))
    Ok(#(code, reader)) -> {
      case state.block_mode && code == clear_code {
        True -> {
          let reader = skip_to_block_boundary(reader, state.n_bits)
          let new_state =
            DecodeState(
              ..state,
              table: dict.new(),
              free_ent: state.first_free,
              n_bits: init_bits,
              max_code: max_code_for(init_bits, state.max_bits),
              codes_at_width: 0,
              has_prev: False,
              prev_code: -1,
            )
          decode_loop(reader, new_state, limits)
        }
        False -> {
          use #(out_rev, out_len, table, prefix_first) <- result.try(emit_code(
            code,
            state.out_rev,
            state.out_len,
            state.table,
            state.prev_code,
            state.has_prev,
            state.free_ent,
            limits,
          ))
          let #(new_table, new_free_ent) = case state.has_prev {
            True -> #(
              dict.insert(table, state.free_ent, #(
                state.prev_code,
                prefix_first,
              )),
              state.free_ent + 1,
            )
            False -> #(table, state.free_ent)
          }
          let new_state =
            DecodeState(
              ..state,
              out_rev: out_rev,
              out_len: out_len,
              table: new_table,
              free_ent: new_free_ent,
              prev_code: code,
              has_prev: True,
            )
          let new_state = promote_decoder_width(new_state, reader)
          let #(new_state, reader) = case new_state.codes_at_width {
            -1 -> {
              let reader = skip_to_block_boundary(reader, state.n_bits)
              #(
                DecodeState(
                  ..new_state,
                  n_bits: new_state.n_bits + 1,
                  max_code: max_code_for(
                    new_state.n_bits + 1,
                    new_state.max_bits,
                  ),
                  codes_at_width: 0,
                ),
                reader,
              )
            }
            _ -> #(new_state, reader)
          }
          decode_loop(reader, new_state, limits)
        }
      }
    }
  }
}

/// The decoder must promote one iteration "earlier" than the encoder
/// because of the classical LZW insertion off-by-one: encoder inserts
/// the `(prefix, byte)` pair at the iter that writes the OLD prefix's
/// code, while the decoder inserts `(prev_code, first_of_current_code)`
/// at the iter that reads the current code — same final entries, but
/// the decoder's `free_ent` lags one bump behind the encoder's view
/// of the stream.  We check `free_ent >= max_code` so the decoder
/// promotes between codes 254 and 255 (when the encoder pads), instead
/// of between codes 255 and 256 (when the decoder's own free_ent would
/// naturally exceed max_code).  Without this, a 256-unique-byte stream
/// reads the encoder's 9-bit pad as a phantom literal code 0.
fn promote_decoder_width(state: DecodeState, _reader: Reader) -> DecodeState {
  case state.free_ent >= state.max_code && state.n_bits < state.max_bits {
    True -> DecodeState(..state, codes_at_width: -1)
    False -> state
  }
}

fn emit_code(
  code: Int,
  out_rev: List(Int),
  out_len: Int,
  table: dict.Dict(Int, #(Int, Int)),
  prev_code: Int,
  has_prev: Bool,
  free_ent: Int,
  limits: limit.Limits,
) -> Result(
  #(List(Int), Int, dict.Dict(Int, #(Int, Int)), Int),
  error.CodecError,
) {
  case code == free_ent && has_prev {
    True -> {
      use first <- result.try(first_char(prev_code, table))
      let extended_table = dict.insert(table, code, #(prev_code, first))
      use #(chars, count) <- result.try(expand_code(code, extended_table))
      use _ <- result.try(check_output_limit(out_len + count, limits))
      Ok(#(prepend_chars(chars, out_rev), out_len + count, table, first))
    }
    False -> {
      use #(chars, count) <- result.try(expand_code(code, table))
      use first <- result.try(first_char_of_chars(chars))
      use _ <- result.try(check_output_limit(out_len + count, limits))
      Ok(#(prepend_chars(chars, out_rev), out_len + count, table, first))
    }
  }
}

fn check_output_limit(
  size: Int,
  limits: limit.Limits,
) -> Result(Nil, error.CodecError) {
  case size > limit.max_output_bytes(limits) {
    True ->
      Error(error.CodecLimitExceeded(limit: "max_output_bytes", actual: size))
    False -> Ok(Nil)
  }
}

fn expand_code(
  code: Int,
  table: dict.Dict(Int, #(Int, Int)),
) -> Result(#(List(Int), Int), error.CodecError) {
  expand_loop(code, table, [], 0)
}

fn expand_loop(
  code: Int,
  table: dict.Dict(Int, #(Int, Int)),
  acc: List(Int),
  count: Int,
) -> Result(#(List(Int), Int), error.CodecError) {
  case code < 256 {
    True -> Ok(#([code, ..acc], count + 1))
    False ->
      case dict.get(table, code) {
        Ok(#(prev, char)) -> expand_loop(prev, table, [char, ..acc], count + 1)
        Error(_) ->
          Error(error.CodecInvalidData(message: "lzw code lookup failed"))
      }
  }
}

fn first_char(
  code: Int,
  table: dict.Dict(Int, #(Int, Int)),
) -> Result(Int, error.CodecError) {
  case code < 256 {
    True -> Ok(code)
    False ->
      case dict.get(table, code) {
        Ok(#(prev, _)) -> first_char(prev, table)
        Error(_) ->
          Error(error.CodecInvalidData(message: "lzw first-char lookup failed"))
      }
  }
}

fn first_char_of_chars(chars: List(Int)) -> Result(Int, error.CodecError) {
  case chars {
    [head, ..] -> Ok(head)
    [] ->
      Error(error.CodecInvalidData(message: "lzw expansion produced no bytes"))
  }
}

fn prepend_chars(chars: List(Int), acc: List(Int)) -> List(Int) {
  case chars {
    [] -> acc
    [head, ..rest] -> prepend_chars(rest, [head, ..acc])
  }
}

fn reverse_to_bit_array(values: List(Int), acc: BitArray) -> BitArray {
  case values {
    [] -> acc
    [head, ..rest] -> reverse_to_bit_array(rest, <<head, acc:bits>>)
  }
}

// -- LSB-first bit writer -----------------------------------------------

type Writer {
  Writer(bytes_rev: List(Int), buffer: Int, bits: Int, bits_written: Int)
}

fn new_writer() -> Writer {
  Writer(bytes_rev: [], buffer: 0, bits: 0, bits_written: 0)
}

fn write_code(writer: Writer, code: Int, n_bits: Int) -> Writer {
  write_bits(writer, code, n_bits)
}

fn write_bits(writer: Writer, value: Int, count: Int) -> Writer {
  case count {
    0 -> writer
    _ -> {
      let masked = int.bitwise_and(value, mask_for(count))
      let buffer =
        int.bitwise_or(
          writer.buffer,
          int.bitwise_shift_left(masked, writer.bits),
        )
      flush_full_bytes(Writer(
        bytes_rev: writer.bytes_rev,
        buffer: buffer,
        bits: writer.bits + count,
        bits_written: writer.bits_written + count,
      ))
    }
  }
}

fn mask_for(count: Int) -> Int {
  int.bitwise_shift_left(1, count) - 1
}

fn flush_full_bytes(writer: Writer) -> Writer {
  case writer.bits >= 8 {
    False -> writer
    True ->
      flush_full_bytes(Writer(
        bytes_rev: [int.bitwise_and(writer.buffer, 0xFF), ..writer.bytes_rev],
        buffer: int.bitwise_shift_right(writer.buffer, 8),
        bits: writer.bits - 8,
        bits_written: writer.bits_written,
      ))
  }
}

fn flush_writer(writer: Writer) -> BitArray {
  let writer = case writer.bits {
    0 -> writer
    _ ->
      Writer(
        bytes_rev: [int.bitwise_and(writer.buffer, 0xFF), ..writer.bytes_rev],
        buffer: 0,
        bits: 0,
        bits_written: writer.bits_written,
      )
  }
  list_reverse_to_bit_array(writer.bytes_rev, <<>>)
}

fn list_reverse_to_bit_array(values: List(Int), acc: BitArray) -> BitArray {
  case values {
    [] -> acc
    [head, ..rest] -> list_reverse_to_bit_array(rest, <<head, acc:bits>>)
  }
}

// -- LSB-first bit reader -----------------------------------------------

type Reader {
  Reader(
    source: BitArray,
    buffer: Int,
    bits: Int,
    bits_read: Int,
    overflow: Bool,
  )
}

fn new_reader(source: BitArray) -> Reader {
  Reader(source: source, buffer: 0, bits: 0, bits_read: 0, overflow: False)
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
              bits_read: reader.bits_read,
              overflow: False,
            ),
            needed,
          )
        _ ->
          Reader(
            source: <<>>,
            buffer: reader.buffer,
            bits: reader.bits,
            bits_read: reader.bits_read,
            overflow: True,
          )
      }
  }
}

fn read_code(reader: Reader, n_bits: Int) -> Result(#(Int, Reader), Nil) {
  let reader = refill(reader, n_bits)
  case reader.bits >= n_bits {
    False -> Error(Nil)
    True -> {
      let mask = mask_for(n_bits)
      let value = int.bitwise_and(reader.buffer, mask)
      Ok(#(
        value,
        Reader(
          source: reader.source,
          buffer: int.bitwise_shift_right(reader.buffer, n_bits),
          bits: reader.bits - n_bits,
          bits_read: reader.bits_read + n_bits,
          overflow: reader.overflow,
        ),
      ))
    }
  }
}

fn skip_to_block_boundary(reader: Reader, n_bits: Int) -> Reader {
  let group_bits = 8 * n_bits
  let leftover = reader.bits_read % group_bits
  case leftover {
    0 -> reader
    _ -> drop_bits(reader, group_bits - leftover)
  }
}

fn drop_bits(reader: Reader, count: Int) -> Reader {
  case count {
    0 -> reader
    _ -> {
      let reader = refill(reader, 1)
      case reader.bits >= 1 {
        False -> reader
        True -> {
          drop_bits(
            Reader(
              source: reader.source,
              buffer: int.bitwise_shift_right(reader.buffer, 1),
              bits: reader.bits - 1,
              bits_read: reader.bits_read + 1,
              overflow: reader.overflow,
            ),
            count - 1,
          )
        }
      }
    }
  }
}
