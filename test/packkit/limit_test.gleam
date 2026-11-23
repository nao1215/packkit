import gleeunit/should
import packkit
import packkit/archive
import packkit/codec
import packkit/fixture
import packkit/internal/cpio
import packkit/internal/entry
import packkit/internal/tar
import packkit/limit

pub fn tar_decoder_enforces_max_entry_name_bytes_test() -> Nil {
  // The new public setter must actually flow into the tar decoder.
  let archive_value =
    fixture.new(archive.Tar) |> fixture.add_file(path: "ten-bytes!", body: <<>>)
  let assert Ok(bytes) = tar.encode(archive: archive_value)
  let tight = limit.Limits(..limit.default(), max_entry_name_bytes: 5)
  case packkit.read_with_limits(bytes, format: archive.Tar, limits: tight) {
    Error(archive.LimitExceeded(limit: "max_entry_name_bytes", actual: _)) ->
      Nil
    _ -> should.fail()
  }
}

// The limits must reach each decoder and stop it.

pub fn zlib_decoder_rejects_window_over_32_kib_test() -> Nil {
  // RFC 1950 does not allow CINFO > 7.  CMF 0x88 with FLG 0x1C passes
  // the mod-31 check, so only the window size is wrong.
  packkit.decompress(<<0x88, 0x1C, 0x03, 0x00, 0, 0, 0, 1>>, with: codec.Zlib)
  |> should.equal(
    Error(codec.InvalidData(message: "zlib: window size is larger than 32 KiB")),
  )
}

pub fn tar_decoder_enforces_max_entry_depth_test() -> Nil {
  // tar already enforced max_entry_depth; this is a fast-running
  // baseline so the cross-family tests can lean on a known-good
  // example.
  let deep =
    fixture.new(archive.Tar)
    |> fixture.add_file(path: "a/b/c/d/e.txt", body: <<"hi":utf8>>)
  let assert Ok(bytes) = tar.encode(archive: deep)
  let tight = limit.Limits(..limit.default(), max_entry_depth: 3)
  case packkit.read_with_limits(bytes, format: archive.Tar, limits: tight) {
    Error(archive.LimitExceeded(limit: "max_entry_depth", actual: 5)) -> Nil
    _ -> should.fail()
  }
}

pub fn cpio_decoder_enforces_max_entry_depth_test() -> Nil {
  // cpio previously skipped the depth check; the limit now applies
  // uniformly across the path-based archive families.
  let assert Ok(deep_file) =
    entry.file_checked(path: "a/b/c/d/file.txt", body: <<"x":utf8>>)
  let deep = fixture.new(archive.Cpio) |> fixture.add(entry: deep_file)
  let assert Ok(bytes) = cpio.encode(archive: deep)
  let tight = limit.Limits(..limit.default(), max_entry_depth: 2)
  case packkit.read_with_limits(bytes, format: archive.Cpio, limits: tight) {
    Error(archive.LimitExceeded(limit: "max_entry_depth", actual: 5)) -> Nil
    _ -> should.fail()
  }
}
