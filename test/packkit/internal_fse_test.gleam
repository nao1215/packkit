import gleam/dict
import gleam/list
import gleeunit/should
import packkit/internal/fse

pub fn predefined_literal_length_total_test() -> Nil {
  // Predefined literal-length distribution must sum to (1 << 6) = 64.
  fse.distribution_total(fse.predefined_literal_length())
  |> should.equal(64)
}

pub fn predefined_match_length_total_test() -> Nil {
  // Predefined match-length distribution must sum to (1 << 6) = 64.
  fse.distribution_total(fse.predefined_match_length())
  |> should.equal(64)
}

pub fn predefined_offset_total_test() -> Nil {
  // Predefined offset distribution must sum to (1 << 5) = 32.
  fse.distribution_total(fse.predefined_offset())
  |> should.equal(32)
}

pub fn literal_length_table_size_test() -> Nil {
  fse.predefined_literal_length_table()
  |> dict.size
  |> should.equal(fse.state_count(fse.predefined_literal_length_log()))
}

pub fn match_length_table_size_test() -> Nil {
  fse.predefined_match_length_table()
  |> dict.size
  |> should.equal(fse.state_count(fse.predefined_match_length_log()))
}

pub fn offset_table_size_test() -> Nil {
  fse.predefined_offset_table()
  |> dict.size
  |> should.equal(fse.state_count(fse.predefined_offset_log()))
}

pub fn high_bit_position_test() -> Nil {
  fse.high_bit_position(1)
  |> should.equal(0)
  fse.high_bit_position(2)
  |> should.equal(1)
  fse.high_bit_position(4)
  |> should.equal(2)
  fse.high_bit_position(7)
  |> should.equal(2)
  fse.high_bit_position(8)
  |> should.equal(3)
  fse.high_bit_position(64)
  |> should.equal(6)
}

pub fn offset_table_covers_all_symbols_test() -> Nil {
  // Every symbol that the predefined offset distribution allocates
  // must appear in the built state table.
  let table = fse.predefined_offset_table()
  let symbols_in_table =
    dict.fold(table, dict.new(), fn(acc, _state, entry) {
      dict.insert(acc, entry.symbol, True)
    })
  let expected_symbols = list.length(fse.predefined_offset())
  dict.size(symbols_in_table)
  |> should.equal(expected_symbols)
}
