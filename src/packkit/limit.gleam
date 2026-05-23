import gleam/bool
import gleam/result

/// Common resource limits shared across archive and codec readers.
pub opaque type Limits {
  Limits(
    max_input_bytes: Int,
    max_output_bytes: Int,
    max_members: Int,
    max_entry_name_bytes: Int,
    max_entry_depth: Int,
    max_window_bits: Int,
  )
}

/// Why a checked limits constructor rejected an argument.
pub type LimitError {
  LimitMustBePositive(name: String, value: Int)
  WindowBitsOutOfRange(value: Int)
}

/// Conservative cross-target defaults for early development.
pub fn default() -> Limits {
  Limits(
    max_input_bytes: 64_000_000,
    max_output_bytes: 256_000_000,
    max_members: 10_000,
    max_entry_name_bytes: 4096,
    max_entry_depth: 32,
    max_window_bits: 15,
  )
}

/// Checked constructor for a full limits value.
pub fn new_checked(
  max_input_bytes max_input_bytes: Int,
  max_output_bytes max_output_bytes: Int,
  max_members max_members: Int,
  max_entry_name_bytes max_entry_name_bytes: Int,
  max_entry_depth max_entry_depth: Int,
  max_window_bits max_window_bits: Int,
) -> Result(Limits, LimitError) {
  positive(name: "max_input_bytes", value: max_input_bytes)
  |> result.try(fn(_) {
    positive(name: "max_output_bytes", value: max_output_bytes)
  })
  |> result.try(fn(_) { positive(name: "max_members", value: max_members) })
  |> result.try(fn(_) {
    positive(name: "max_entry_name_bytes", value: max_entry_name_bytes)
  })
  |> result.try(fn(_) {
    positive(name: "max_entry_depth", value: max_entry_depth)
  })
  |> result.try(fn(_) { validate_window_bits(max_window_bits) })
  |> result.map(fn(_) {
    Limits(
      max_input_bytes: max_input_bytes,
      max_output_bytes: max_output_bytes,
      max_members: max_members,
      max_entry_name_bytes: max_entry_name_bytes,
      max_entry_depth: max_entry_depth,
      max_window_bits: max_window_bits,
    )
  })
}

/// Panicking counterpart of `new_checked`.
pub fn new(
  max_input_bytes max_input_bytes: Int,
  max_output_bytes max_output_bytes: Int,
  max_members max_members: Int,
  max_entry_name_bytes max_entry_name_bytes: Int,
  max_entry_depth max_entry_depth: Int,
  max_window_bits max_window_bits: Int,
) -> Limits {
  case
    new_checked(
      max_input_bytes: max_input_bytes,
      max_output_bytes: max_output_bytes,
      max_members: max_members,
      max_entry_name_bytes: max_entry_name_bytes,
      max_entry_depth: max_entry_depth,
      max_window_bits: max_window_bits,
    )
  {
    Ok(limits) -> limits
    Error(LimitMustBePositive(name, _)) ->
      panic as { "packkit/limit.new: " <> name <> " must be > 0" }
    Error(WindowBitsOutOfRange(_)) ->
      panic as "packkit/limit.new: max_window_bits must be in the inclusive range 8..30"
  }
}

/// Read `max_input_bytes`.
pub fn max_input_bytes(limits: Limits) -> Int {
  limits.max_input_bytes
}

/// Read `max_output_bytes`.
pub fn max_output_bytes(limits: Limits) -> Int {
  limits.max_output_bytes
}

/// Read `max_members`.
pub fn max_members(limits: Limits) -> Int {
  limits.max_members
}

/// Read `max_entry_name_bytes`.
pub fn max_entry_name_bytes(limits: Limits) -> Int {
  limits.max_entry_name_bytes
}

/// Read `max_entry_depth`.
pub fn max_entry_depth(limits: Limits) -> Int {
  limits.max_entry_depth
}

/// Read `max_window_bits`.
pub fn max_window_bits(limits: Limits) -> Int {
  limits.max_window_bits
}

/// Update `max_input_bytes` after validation.
pub fn with_max_input_bytes_checked(
  limits: Limits,
  bytes bytes: Int,
) -> Result(Limits, LimitError) {
  positive(name: "max_input_bytes", value: bytes)
  |> result.map(fn(_) { Limits(..limits, max_input_bytes: bytes) })
}

/// Update `max_output_bytes` after validation.
pub fn with_max_output_bytes_checked(
  limits: Limits,
  bytes bytes: Int,
) -> Result(Limits, LimitError) {
  positive(name: "max_output_bytes", value: bytes)
  |> result.map(fn(_) { Limits(..limits, max_output_bytes: bytes) })
}

/// Update `max_members` after validation.
pub fn with_max_members_checked(
  limits: Limits,
  count count: Int,
) -> Result(Limits, LimitError) {
  positive(name: "max_members", value: count)
  |> result.map(fn(_) { Limits(..limits, max_members: count) })
}

/// Update `max_entry_depth` after validation.
pub fn with_max_entry_depth_checked(
  limits: Limits,
  depth depth: Int,
) -> Result(Limits, LimitError) {
  positive(name: "max_entry_depth", value: depth)
  |> result.map(fn(_) { Limits(..limits, max_entry_depth: depth) })
}

/// Update `max_window_bits` after validation.
pub fn with_max_window_bits_checked(
  limits: Limits,
  bits bits: Int,
) -> Result(Limits, LimitError) {
  validate_window_bits(bits)
  |> result.map(fn(_) { Limits(..limits, max_window_bits: bits) })
}

/// Unchecked setter for `max_input_bytes`.  The caller is responsible
/// for passing a positive value; non-positive values are clamped to 1
/// to keep downstream decoders well-behaved.
pub fn with_max_input_bytes(limits: Limits, bytes bytes: Int) -> Limits {
  Limits(..limits, max_input_bytes: clamp_positive(bytes))
}

/// Unchecked setter for `max_output_bytes`.  See [with_max_input_bytes]
/// for the contract.
pub fn with_max_output_bytes(limits: Limits, bytes bytes: Int) -> Limits {
  Limits(..limits, max_output_bytes: clamp_positive(bytes))
}

/// Unchecked setter for `max_members`.
pub fn with_max_members(limits: Limits, count count: Int) -> Limits {
  Limits(..limits, max_members: clamp_positive(count))
}

/// Unchecked setter for `max_entry_depth`.
pub fn with_max_entry_depth(limits: Limits, depth depth: Int) -> Limits {
  Limits(..limits, max_entry_depth: clamp_positive(depth))
}

/// Unchecked setter for `max_window_bits`.  Out-of-range values are
/// clamped to the valid 8..30 window.
pub fn with_max_window_bits(limits: Limits, bits bits: Int) -> Limits {
  let clamped = case bits {
    n if n < 8 -> 8
    n if n > 30 -> 30
    n -> n
  }
  Limits(..limits, max_window_bits: clamped)
}

fn clamp_positive(value: Int) -> Int {
  case value {
    n if n < 1 -> 1
    n -> n
  }
}

fn positive(name name: String, value value: Int) -> Result(Nil, LimitError) {
  use <- bool.guard(
    when: value <= 0,
    return: Error(LimitMustBePositive(name: name, value: value)),
  )
  Ok(Nil)
}

fn validate_window_bits(bits: Int) -> Result(Nil, LimitError) {
  use <- bool.guard(
    when: bits < 8 || bits > 30,
    return: Error(WindowBitsOutOfRange(bits)),
  )
  Ok(Nil)
}
