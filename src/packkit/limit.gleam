//// Resource limits for decoding untrusted input.

/// Upper bounds a decoder checks while it reads. Going over any of them
/// returns a `LimitExceeded` error instead of using more memory. Each
/// field must be positive; a limit of 0 rejects every input.
///
/// Change one field with the record update syntax:
///
/// ```gleam
/// Limits(..limit.default(), max_input_bytes: 1_000_000)
/// ```
///
pub type Limits {
  Limits(
    /// Size of the compressed input. (default: 64_000_000)
    max_input_bytes: Int,
    /// Size of the decompressed output. (default: 256_000_000)
    max_output_bytes: Int,
    /// Number of entries in an archive. (default: 10_000)
    max_members: Int,
    /// Length of an entry path in bytes. (default: 4096)
    max_entry_name_bytes: Int,
    /// Number of path segments in an entry path, so `a/b/c` is 3.
    /// (default: 32)
    max_entry_depth: Int,
  )
}

/// Returns the default limits listed on the fields of `Limits`.
///
pub fn default() -> Limits {
  Limits(
    max_input_bytes: 64_000_000,
    max_output_bytes: 256_000_000,
    max_members: 10_000,
    max_entry_name_bytes: 4096,
    max_entry_depth: 32,
  )
}
