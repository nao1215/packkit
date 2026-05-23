import gleeunit/should
import packkit/limit

pub fn unchecked_with_max_input_bytes_sets_value_test() -> Nil {
  limit.default()
  |> limit.with_max_input_bytes(bytes: 1024)
  |> limit.max_input_bytes
  |> should.equal(1024)
}

pub fn unchecked_with_max_output_bytes_sets_value_test() -> Nil {
  limit.default()
  |> limit.with_max_output_bytes(bytes: 8192)
  |> limit.max_output_bytes
  |> should.equal(8192)
}

pub fn unchecked_with_max_members_sets_value_test() -> Nil {
  limit.default()
  |> limit.with_max_members(count: 64)
  |> limit.max_members
  |> should.equal(64)
}

pub fn unchecked_with_max_entry_depth_sets_value_test() -> Nil {
  limit.default()
  |> limit.with_max_entry_depth(depth: 5)
  |> limit.max_entry_depth
  |> should.equal(5)
}

pub fn unchecked_with_max_window_bits_clamps_low_test() -> Nil {
  limit.default()
  |> limit.with_max_window_bits(bits: 4)
  |> limit.max_window_bits
  |> should.equal(8)
}

pub fn unchecked_with_max_window_bits_clamps_high_test() -> Nil {
  limit.default()
  |> limit.with_max_window_bits(bits: 99)
  |> limit.max_window_bits
  |> should.equal(30)
}

pub fn unchecked_setters_clamp_non_positive_test() -> Nil {
  // The unchecked setters guarantee a minimum of 1 so downstream
  // decoders never see a zero/negative limit.
  limit.default()
  |> limit.with_max_input_bytes(bytes: -1)
  |> limit.max_input_bytes
  |> should.equal(1)

  limit.default()
  |> limit.with_max_members(count: 0)
  |> limit.max_members
  |> should.equal(1)
}
