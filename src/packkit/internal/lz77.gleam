//// Match-finder helpers shared by the LZ77-style encoders. DEFLATE,
//// LZMA, Zstandard and Brotli read bytes straight from the input; LZ4,
//// Snappy and DEFLATE's other path index a `Dict` built once with
//// `table`.

import gleam/bool
import gleam/dict.{type Dict}
import gleam/int

/// Returns the byte at `pos`, or 0 outside `bytes`.
pub fn byte_at(bytes: BitArray, pos: Int) -> Int {
  use <- bool.guard(when: pos < 0, return: 0)
  case bytes {
    <<_:bytes-size(pos), byte, _:bytes>> -> byte
    _ -> 0
  }
}

/// Counts the equal bytes at `a + count` and `b + count`, going up from
/// `count` and stopping at `cap`.
pub fn match_length(
  bytes: BitArray,
  a: Int,
  b: Int,
  cap: Int,
  count: Int,
) -> Int {
  case count >= cap {
    True -> count
    False ->
      case byte_at(bytes, a + count) == byte_at(bytes, b + count) {
        True -> match_length(bytes, a, b, cap, count + 1)
        False -> count
      }
  }
}

/// A 16-bit hash of three bytes.
pub fn hash3(b0: Int, b1: Int, b2: Int) -> Int {
  int.bitwise_and(
    int.bitwise_exclusive_or(
      int.bitwise_exclusive_or(b0 * 2_654_435_761, b1 * 40_503),
      b2 * 2_246_822_519,
    ),
    0xFFFF,
  )
}

/// Records the position of each 3-byte string that starts in `from` up to
/// but not including `to`, keyed by `hash3`, while three bytes remain
/// before `size`.
pub fn insert_hashes3(
  bytes: BitArray,
  hashes: Dict(Int, Int),
  from: Int,
  to: Int,
  size: Int,
) -> Dict(Int, Int) {
  case from >= to || from + 3 > size {
    True -> hashes
    False -> {
      let key =
        hash3(
          byte_at(bytes, from),
          byte_at(bytes, from + 1),
          byte_at(bytes, from + 2),
        )
      insert_hashes3(bytes, dict.insert(hashes, key, from), from + 1, to, size)
    }
  }
}

/// Indexes every byte of `bytes` by its position.
pub fn table(bytes: BitArray) -> Dict(Int, Int) {
  table_loop(bytes, 0, dict.new())
}

fn table_loop(
  bytes: BitArray,
  index: Int,
  acc: Dict(Int, Int),
) -> Dict(Int, Int) {
  case bytes {
    <<b, rest:bytes>> -> table_loop(rest, index + 1, dict.insert(acc, index, b))
    _ -> acc
  }
}

/// Returns the byte at `index` of a `table`, or 0 past the end.
pub fn table_at(table: Dict(Int, Int), index: Int) -> Int {
  case dict.get(table, index) {
    Ok(b) -> b
    Error(Nil) -> 0
  }
}

/// A 16-bit hash of four bytes, used by LZ4 and Snappy. The hash is not
/// part of either format; it only decides which matches are found.
pub fn hash4(b0: Int, b1: Int, b2: Int, b3: Int) -> Int {
  let combined =
    int.bitwise_or(
      b0,
      int.bitwise_or(
        int.bitwise_shift_left(b1, 8),
        int.bitwise_or(
          int.bitwise_shift_left(b2, 16),
          int.bitwise_shift_left(b3, 24),
        ),
      ),
    )
  int.bitwise_and(combined * 2_654_435_761, 0xFFFF)
}

/// Reports whether the four bytes at `p1` and at `p2` are equal.
pub fn same4(table: Dict(Int, Int), p1: Int, p2: Int) -> Bool {
  table_at(table, p1) == table_at(table, p2)
  && table_at(table, p1 + 1) == table_at(table, p2 + 1)
  && table_at(table, p1 + 2) == table_at(table, p2 + 2)
  && table_at(table, p1 + 3) == table_at(table, p2 + 3)
}

/// Counts the equal bytes at `base + acc` and `cursor + acc`, going up
/// from `acc` while `cursor + acc` is before `limit_pos`.
pub fn table_match_length(
  table: Dict(Int, Int),
  base: Int,
  cursor: Int,
  limit_pos: Int,
  acc: Int,
) -> Int {
  case cursor + acc >= limit_pos {
    True -> acc
    False ->
      case table_at(table, base + acc) == table_at(table, cursor + acc) {
        True -> table_match_length(table, base, cursor, limit_pos, acc + 1)
        False -> acc
      }
  }
}

/// Records the position of each 4-byte string that starts in `from` up to
/// and including `to`, keyed by `hash4`, while four bytes remain before
/// `size`.
pub fn insert_hashes4(
  table: Dict(Int, Int),
  hashes: Dict(Int, Int),
  from: Int,
  to: Int,
  size: Int,
) -> Dict(Int, Int) {
  case from > to || from + 4 > size {
    True -> hashes
    False -> {
      let key =
        hash4(
          table_at(table, from),
          table_at(table, from + 1),
          table_at(table, from + 2),
          table_at(table, from + 3),
        )
      insert_hashes4(table, dict.insert(hashes, key, from), from + 1, to, size)
    }
  }
}

/// Copies `count` bytes of a `table` starting at `start`.
pub fn table_slice(table: Dict(Int, Int), start: Int, count: Int) -> BitArray {
  table_slice_loop(table, start, count, <<>>)
}

fn table_slice_loop(
  table: Dict(Int, Int),
  start: Int,
  count: Int,
  acc: BitArray,
) -> BitArray {
  case count <= 0 {
    True -> acc
    False ->
      table_slice_loop(table, start + 1, count - 1, <<
        acc:bits,
        table_at(table, start),
      >>)
  }
}
