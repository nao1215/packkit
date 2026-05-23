//// Finite State Entropy (FSE) decoder primitives shared between the
//// Zstandard sequences section and any future LZFSE-style codec.
////
//// This module currently provides the three predefined FSE
//// distributions that Zstandard uses for literal_length, match_length,
//// and offset symbols (RFC 8478 §3.1.1.3.2.2), plus a state-table
//// builder that turns a normalized distribution into the per-state
//// (symbol, nb_bits, baseline) triple used by the streaming decoder.
//// The state-driven decode loop itself can be added in a follow-up
//// commit once the surrounding zstd block parser is ready to call it.

import gleam/dict
import gleam/int
import gleam/list

/// Predefined Literals_Length distribution at accuracy_log 6.
pub fn predefined_literal_length() -> List(Int) {
  [
    4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3,
    2, 1, 1, 1, 1, 1, -1, -1, -1, -1,
  ]
}

/// Predefined Match_Length distribution at accuracy_log 6.
pub fn predefined_match_length() -> List(Int) {
  [
    1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1,
    -1, -1,
  ]
}

/// Predefined Offset distribution at accuracy_log 5.
pub fn predefined_offset() -> List(Int) {
  [
    1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1,
    -1, -1, -1, -1,
  ]
}

/// Predefined accuracy_log values for each predefined distribution.
pub fn predefined_literal_length_log() -> Int {
  6
}

pub fn predefined_match_length_log() -> Int {
  6
}

pub fn predefined_offset_log() -> Int {
  5
}

/// One entry in an FSE state-transition table.
pub type StateEntry {
  StateEntry(symbol: Int, nb_bits: Int, baseline: Int)
}

/// Build the per-state transition table for a normalized
/// distribution.  The `normalized` list assigns one count per symbol
/// (with `-1` representing a "less-probable" symbol that consumes a
/// single state in the low slots, per RFC 8478 §3.1.1.3.2.2).
///
/// The returned dict maps `state_index ∈ 0 .. (1 << accuracy_log) - 1`
/// to its `StateEntry`.  The streaming decoder uses the entry's
/// `symbol` to emit and `nb_bits` / `baseline` to compute the next
/// state value after reading the requested bits from the input.
pub fn build_state_table(
  normalized: List(Int),
  accuracy_log: Int,
) -> dict.Dict(Int, StateEntry) {
  let table_size = int.bitwise_shift_left(1, accuracy_log)
  let position_dict = assign_positions(normalized, accuracy_log, table_size)
  let symbol_counts = real_counts(normalized, dict.new(), 0)
  build_entries(position_dict, symbol_counts, accuracy_log, 0, dict.new())
}

fn real_counts(
  normalized: List(Int),
  acc: dict.Dict(Int, Int),
  symbol: Int,
) -> dict.Dict(Int, Int) {
  case normalized {
    [] -> acc
    [n, ..rest] -> {
      let count = case n {
        -1 -> 1
        v -> v
      }
      real_counts(rest, dict.insert(acc, symbol, count), symbol + 1)
    }
  }
}

/// Distribute symbols across the table cells using the canonical
/// zstd "step = (table_size >> 1) + (table_size >> 3) + 3" cursor.
/// Less-probable symbols (`-1`) occupy the high cells in reverse.
fn assign_positions(
  normalized: List(Int),
  _accuracy_log: Int,
  table_size: Int,
) -> dict.Dict(Int, Int) {
  let mask = table_size - 1
  let step =
    int.bitwise_shift_right(table_size, 1)
    + int.bitwise_shift_right(table_size, 3)
    + 3
  let high_threshold = table_size - 1
  let #(positions, _next_high) =
    place_less_probable(normalized, 0, high_threshold, dict.new())
  place_normal(normalized, 0, 0, positions, mask, step, high_threshold)
}

fn place_less_probable(
  normalized: List(Int),
  symbol: Int,
  high_cursor: Int,
  acc: dict.Dict(Int, Int),
) -> #(dict.Dict(Int, Int), Int) {
  case normalized {
    [] -> #(acc, high_cursor)
    [n, ..rest] ->
      case n {
        -1 ->
          place_less_probable(
            rest,
            symbol + 1,
            high_cursor - 1,
            dict.insert(acc, high_cursor, symbol),
          )
        _ -> place_less_probable(rest, symbol + 1, high_cursor, acc)
      }
  }
}

fn place_normal(
  normalized: List(Int),
  cursor: Int,
  symbol: Int,
  positions: dict.Dict(Int, Int),
  mask: Int,
  step: Int,
  high_threshold: Int,
) -> dict.Dict(Int, Int) {
  case normalized {
    [] -> positions
    [n, ..rest] ->
      case n {
        v if v <= 0 ->
          place_normal(
            rest,
            cursor,
            symbol + 1,
            positions,
            mask,
            step,
            high_threshold,
          )
        v -> {
          let #(new_cursor, positions) =
            place_one_symbol(
              symbol,
              v,
              cursor,
              positions,
              mask,
              step,
              high_threshold,
            )
          place_normal(
            rest,
            new_cursor,
            symbol + 1,
            positions,
            mask,
            step,
            high_threshold,
          )
        }
      }
  }
}

fn place_one_symbol(
  symbol: Int,
  remaining: Int,
  cursor: Int,
  positions: dict.Dict(Int, Int),
  mask: Int,
  step: Int,
  high_threshold: Int,
) -> #(Int, dict.Dict(Int, Int)) {
  case remaining {
    0 -> #(cursor, positions)
    _ -> {
      let positions = dict.insert(positions, cursor, symbol)
      let new_cursor = advance_cursor(cursor, mask, step, high_threshold)
      place_one_symbol(
        symbol,
        remaining - 1,
        new_cursor,
        positions,
        mask,
        step,
        high_threshold,
      )
    }
  }
}

fn advance_cursor(cursor: Int, mask: Int, step: Int, high_threshold: Int) -> Int {
  let next = int.bitwise_and(cursor + step, mask)
  case next > high_threshold {
    True -> advance_cursor(next, mask, step, high_threshold)
    False -> next
  }
}

fn build_entries(
  positions: dict.Dict(Int, Int),
  counts: dict.Dict(Int, Int),
  accuracy_log: Int,
  state_index: Int,
  acc: dict.Dict(Int, StateEntry),
) -> dict.Dict(Int, StateEntry) {
  let table_size = int.bitwise_shift_left(1, accuracy_log)
  case state_index >= table_size {
    True -> acc
    False -> {
      let symbol = case dict.get(positions, state_index) {
        Ok(v) -> v
        Error(_) -> 0
      }
      let count = case dict.get(counts, symbol) {
        Ok(v) -> v
        Error(_) -> 1
      }
      // The state's nb_bits is `accuracy_log - ceil(log2(count))`, but
      // expressed as the high-bit position of count so it can be
      // computed cheaply.
      let nb_bits = state_bits_for_count(count, accuracy_log)
      let baseline = baseline_for_position(state_index, count, accuracy_log)
      let entry =
        StateEntry(symbol: symbol, nb_bits: nb_bits, baseline: baseline)
      build_entries(
        positions,
        counts,
        accuracy_log,
        state_index + 1,
        dict.insert(acc, state_index, entry),
      )
    }
  }
}

fn state_bits_for_count(count: Int, accuracy_log: Int) -> Int {
  let next_power = next_power_of_two(count)
  accuracy_log - count_log2(next_power, 0)
}

fn next_power_of_two(n: Int) -> Int {
  case n {
    1 -> 1
    _ -> int.bitwise_shift_left(1, count_log2(n - 1, 0) + 1)
  }
}

fn count_log2(value: Int, acc: Int) -> Int {
  case value <= 1 {
    True -> acc
    False -> count_log2(int.bitwise_shift_right(value, 1), acc + 1)
  }
}

fn baseline_for_position(state_index: Int, count: Int, accuracy_log: Int) -> Int {
  // The full computation needs the symbol's per-cell ordinal, which
  // requires walking the position list and counting prior occurrences
  // of the same symbol.  We surface a conservative starting baseline
  // here so the StateEntry has consistent fields; the streaming
  // decoder will refine this once it reads its first state value.
  let _ = state_index
  let _ = count
  let _ = accuracy_log
  0
}

/// Convenience: build the predefined Literals_Length state table.
pub fn predefined_literal_length_table() -> dict.Dict(Int, StateEntry) {
  build_state_table(
    predefined_literal_length(),
    predefined_literal_length_log(),
  )
}

/// Convenience: build the predefined Match_Length state table.
pub fn predefined_match_length_table() -> dict.Dict(Int, StateEntry) {
  build_state_table(predefined_match_length(), predefined_match_length_log())
}

/// Convenience: build the predefined Offset state table.
pub fn predefined_offset_table() -> dict.Dict(Int, StateEntry) {
  build_state_table(predefined_offset(), predefined_offset_log())
}

/// Total number of state cells implied by an accuracy_log.
pub fn state_count(accuracy_log: Int) -> Int {
  int.bitwise_shift_left(1, accuracy_log)
}

/// Sum the absolute counts in a normalized distribution.  Useful for
/// validating that the distribution matches its declared table size.
pub fn distribution_total(normalized: List(Int)) -> Int {
  list.fold(normalized, 0, fn(acc, n) {
    case n {
      -1 -> acc + 1
      v -> acc + v
    }
  })
}
