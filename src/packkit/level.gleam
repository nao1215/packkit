import gleam/bool
import gleam/int

/// Compression level abstraction shared by codecs that expose a
/// roughly "store .. best" numeric axis.
pub opaque type Level {
  Level(value: Int, label: String)
}

/// Why a checked level constructor rejected the requested value.
pub type LevelError {
  LevelOutOfRange(value: Int)
}

/// Zero-compression / store mode.
pub fn store() -> Level {
  Level(value: 0, label: "store")
}

/// Fastest practical compression setting.
pub fn fast() -> Level {
  Level(value: 1, label: "fast")
}

/// Project-default balanced setting.
pub fn default() -> Level {
  Level(value: 6, label: "default")
}

/// Human-friendly balanced alias.
pub fn balanced() -> Level {
  default()
}

/// Highest generic compression setting.
pub fn best() -> Level {
  Level(value: 9, label: "best")
}

/// Build a custom level or return a typed error when it falls outside
/// the current generic range of `0..9`.
pub fn custom_checked(value value: Int) -> Result(Level, LevelError) {
  use <- bool.guard(
    when: value < 0 || value > 9,
    return: Error(LevelOutOfRange(value)),
  )
  Ok(Level(value: value, label: "custom-" <> int.to_string(value)))
}

/// Panicking counterpart of `custom_checked`.
pub fn custom(value value: Int) -> Level {
  case custom_checked(value: value) {
    Ok(level) -> level
    Error(LevelOutOfRange(_)) ->
      panic as "packkit/level.custom: level must be in the inclusive range 0..9"
  }
}

/// Numeric value for a level.
pub fn value(level: Level) -> Int {
  level.value
}

/// Stable string label for docs, tests, and diagnostics.
pub fn label(level: Level) -> String {
  level.label
}
