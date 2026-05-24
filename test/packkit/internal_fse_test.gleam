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

pub fn predefined_ml_state_38_symbol_test() -> Nil {
  // Reference zstd's ML_defaultDTable places match-length code 36 at
  // state 38 (with baseVal 43, the base for ML_code 36 per RFC 8478).
  // Verified against the static table in
  // doc/reference/zstd/lib/decompress/zstd_decompress_block.c
  // (ZSTD_seqSymbol ML_defaultDTable).  If this stops matching, every
  // sequences decode will diverge.
  let table = fse.predefined_match_length_table()
  let assert Ok(entry) = dict.get(table, 38)
  entry.symbol
  |> should.equal(36)
}

pub fn predefined_ll_state_37_symbol_test() -> Nil {
  let table = fse.predefined_literal_length_table()
  let assert Ok(entry) = dict.get(table, 37)
  entry.symbol
  |> should.equal(23)
}

pub fn predefined_offset_state_10_symbol_test() -> Nil {
  let table = fse.predefined_offset_table()
  let assert Ok(entry) = dict.get(table, 10)
  entry.symbol
  |> should.equal(5)
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

pub fn backward_reader_skips_padding_and_marker_test() -> Nil {
  // Last byte 0x02 = 0b00000010 → marker bit at position 1, padding
  // bits at positions 7-2 (all zero).  Bits below the marker (just
  // bit 0 = 0) form the initial buffer.
  let assert Ok(reader) = fse.new_backward_reader(<<0x02>>)
  // No further bits available → asking for 1 bit returns 0.
  let assert Ok(#(value, _)) = fse.read_backward_bits(reader, 1)
  value
  |> should.equal(0)
}

pub fn backward_reader_consumes_full_byte_after_marker_test() -> Nil {
  // 0xC0 0x02 — last byte (0x02) gives 1 bit (0) below the marker;
  // pulling another 8 bits should pour in the 0xC0 byte MSB-first.
  let assert Ok(reader) = fse.new_backward_reader(<<0xC0, 0x02>>)
  // First read consumes the 1 bit below the marker.
  let assert Ok(#(low, reader)) = fse.read_backward_bits(reader, 1)
  low
  |> should.equal(0)
  // The next 8 bits should equal 0xC0 (11000000).
  let assert Ok(#(byte, _)) = fse.read_backward_bits(reader, 8)
  byte
  |> should.equal(0xC0)
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
