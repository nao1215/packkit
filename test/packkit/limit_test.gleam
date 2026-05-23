import gleeunit/should
import packkit/archive
import packkit/cpio
import packkit/entry
import packkit/error
import packkit/limit
import packkit/tar
import packkit/zlib

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

pub fn unchecked_with_max_entry_name_bytes_sets_value_test() -> Nil {
  limit.default()
  |> limit.with_max_entry_name_bytes(bytes: 64)
  |> limit.max_entry_name_bytes
  |> should.equal(64)
}

pub fn unchecked_with_max_entry_name_bytes_clamps_non_positive_test() -> Nil {
  limit.default()
  |> limit.with_max_entry_name_bytes(bytes: 0)
  |> limit.max_entry_name_bytes
  |> should.equal(1)
}

pub fn checked_with_max_entry_name_bytes_rejects_non_positive_test() -> Nil {
  case limit.with_max_entry_name_bytes_checked(limit.default(), bytes: 0) {
    Error(limit.LimitMustBePositive(name: "max_entry_name_bytes", value: 0)) ->
      Nil
    _ -> should.fail()
  }
}

pub fn tar_decoder_enforces_max_entry_name_bytes_test() -> Nil {
  // The new public setter must actually flow into the tar decoder.
  let archive_value = tar.new() |> tar.add_file(path: "ten-bytes!", body: <<>>)
  let assert Ok(bytes) = tar.encode(archive: archive_value)
  let assert Ok(tight) =
    limit.with_max_entry_name_bytes_checked(limit.default(), bytes: 5)
  case tar.decode_with_limits(bytes: bytes, limits: tight) {
    Error(error.ArchiveLimitExceeded(limit: "max_entry_name_bytes", actual: _)) ->
      Nil
    _ -> should.fail()
  }
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

// -- enforcement tests --------------------------------------------------
//
// The Limits contract used to advertise knobs that no decoder actually
// consulted (`max_window_bits`, plus `max_entry_depth` outside tar).
// These tests pin down that the values now drive real refusals.

pub fn zlib_decoder_enforces_max_window_bits_test() -> Nil {
  // The default zlib stream uses CINFO=7 → window_bits=15.  Lowering
  // the limit below 15 should cause the decoder to refuse.
  let payload = <<"window-bits enforcement check":utf8>>
  let assert Ok(stream) = zlib.encode(bytes: payload)
  let tight = limit.default() |> limit.with_max_window_bits(bits: 14)
  case zlib.decode_with_limits(bytes: stream, limits: tight) {
    Error(error.CodecLimitExceeded(limit: "max_window_bits", actual: 15)) -> Nil
    _ -> should.fail()
  }
}

pub fn zlib_decoder_accepts_matching_max_window_bits_test() -> Nil {
  let payload = <<"window-bits enforcement positive":utf8>>
  let assert Ok(stream) = zlib.encode(bytes: payload)
  let ok_limits = limit.default() |> limit.with_max_window_bits(bits: 15)
  let assert Ok(restored) =
    zlib.decode_with_limits(bytes: stream, limits: ok_limits)
  restored
  |> should.equal(payload)
}

pub fn tar_decoder_enforces_max_entry_depth_test() -> Nil {
  // tar already enforced max_entry_depth; this is a fast-running
  // baseline so the cross-family tests can lean on a known-good
  // example.
  let deep =
    tar.new()
    |> tar.add_file(path: "a/b/c/d/e.txt", body: <<"hi":utf8>>)
  let assert Ok(bytes) = tar.encode(archive: deep)
  let tight = limit.default() |> limit.with_max_entry_depth(depth: 3)
  case tar.decode_with_limits(bytes: bytes, limits: tight) {
    Error(error.ArchiveLimitExceeded(limit: "max_entry_depth", actual: 5)) ->
      Nil
    _ -> should.fail()
  }
}

pub fn cpio_decoder_enforces_max_entry_depth_test() -> Nil {
  // cpio previously skipped the depth check; the limit now applies
  // uniformly across the path-based archive families.
  let assert Ok(deep_file) =
    entry.file_checked(path: "a/b/c/d/file.txt", body: <<"x":utf8>>)
  let deep = archive.new(format: cpio.format()) |> archive.add(entry: deep_file)
  let assert Ok(bytes) = cpio.encode(archive: deep)
  let tight = limit.default() |> limit.with_max_entry_depth(depth: 2)
  case cpio.decode_with_limits(bytes: bytes, limits: tight) {
    Error(error.ArchiveLimitExceeded(limit: "max_entry_depth", actual: 5)) ->
      Nil
    _ -> should.fail()
  }
}
