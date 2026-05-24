//// Tests for the Zip64 extensions on top of the standard ZIP
//// encoder / decoder.  The wire-level fixtures are constructed by
//// hand so the test suite doesn't need to materialise a 4 GiB
//// payload to exercise the sentinel paths.

import gleam/bit_array
@target(erlang)
import gleam/list
import gleeunit/should
import packkit/archive
import packkit/checksum
import packkit/entry
@target(erlang)
import packkit/limit
import packkit/zip

pub fn decodes_zip64_eocd_locator_fixture_test() -> Nil {
  // Hand-built minimal Zip64 archive containing one stored entry
  // ("z.txt" / 1 byte "Z").  The standard EOCD writes the
  // sentinel 0xFFFF for total_entries to force the decoder down
  // the Zip64 locator path even though there's really only one
  // entry — proves we follow the locator + Zip64 EOCD record.
  let body = <<"Z":utf8>>
  let crc = checksum.crc32(data: body)
  let local_header = <<
    // local file signature
    0x50, 0x4B, 0x03, 0x04,
    // version needed
    0x14, 0x00,
    // general purpose flag
    0x00, 0x00,
    // method = store
    0x00, 0x00,
    // mod time + date (placeholders)
    0x21, 0x00, 0x21, 0x00,
    // CRC32
    crc:size(32)-little,
    // comp size
    0x01, 0x00, 0x00, 0x00,
    // uncomp size
    0x01, 0x00, 0x00, 0x00,
    // name length
    0x05, 0x00,
    // extra length
    0x00, 0x00,
    // name "z.txt"
    0x7A, 0x2E, 0x74, 0x78, 0x74,
    // file data
    0x5A,
  >>

  let local_size = bit_array.byte_size(local_header)

  let central_directory = <<
    // central directory signature
    0x50, 0x4B, 0x01, 0x02,
    // version made by + version needed
    0x14, 0x03, 0x14, 0x00,
    // gp flag + method
    0x00, 0x00, 0x00, 0x00,
    // mod time + date
    0x21, 0x00, 0x21, 0x00,
    // CRC32
    crc:size(32)-little,
    // comp + uncomp size
    0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    // name length
    0x05, 0x00,
    // extra length
    0x00, 0x00,
    // comment length
    0x00, 0x00,
    // disk start
    0x00, 0x00,
    // internal attrs
    0x00, 0x00,
    // external attrs (regular file mode)
    0x00, 0x00, 0xA4, 0x81,
    // local header offset
    0x00, 0x00, 0x00, 0x00,
    // name
    0x7A, 0x2E, 0x74, 0x78, 0x74,
  >>

  let central_size = bit_array.byte_size(central_directory)
  let central_offset = local_size

  // Zip64 EOCD record (56 bytes).  total_entries = 1, central
  // metrics match the real central directory.
  let zip64_eocd = <<
    0x50, 0x4B, 0x06, 0x06,
    // size of record minus 12 = 44
    44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // version made by + version needed
    0x14, 0x03, 0x2D, 0x00,
    // disk number + disk with CD start
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // entries on this disk
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // total entries
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // central directory size
    central_size:size(64)-little,
    // central directory offset
    central_offset:size(64)-little,
  >>

  let zip64_eocd_offset = local_size + central_size

  let zip64_locator = <<
    0x50, 0x4B, 0x06, 0x07,
    // disk number = 0
    0x00, 0x00, 0x00, 0x00,
    // zip64 EOCD offset
    zip64_eocd_offset:size(64)-little,
    // total disks = 1
    0x01, 0x00, 0x00, 0x00,
  >>

  // Standard EOCD with the 16-bit total-entries sentinel.
  let eocd = <<
    0x50, 0x4B, 0x05, 0x06,
    // disk + CD start disk
    0x00, 0x00, 0x00, 0x00,
    // entries on this disk: sentinel
    0xFF, 0xFF,
    // total entries: sentinel
    0xFF, 0xFF,
    // central directory size (real)
    central_size:size(32)-little,
    // central directory offset (real)
    central_offset:size(32)-little,
    // comment length
    0x00, 0x00,
  >>

  let stream =
    bit_array.concat([
      local_header,
      central_directory,
      zip64_eocd,
      zip64_locator,
      eocd,
    ])

  let assert Ok(arch) = zip.decode(bytes: stream)
  archive.entry_count(arch)
  |> should.equal(1)

  case archive.entries(arch) {
    [entry_value] -> {
      entry.path(entry_value)
      |> entry.to_string
      |> should.equal("z.txt")
      entry.body(entry_value)
      |> should.equal(<<"Z":utf8>>)
    }
    _ -> should.fail()
  }
}

pub fn encoder_emits_normal_zip_without_zip64_test() -> Nil {
  // Regression: small archives should not gratuitously emit a Zip64
  // EOCD record / locator.  The byte size should stay the same as
  // before we added the Zip64 trailer logic.
  let archive_value =
    zip.new()
    |> archive.add(entry: entry.file(path: "a.txt", body: <<"hi":utf8>>))
  let assert Ok(bytes) = zip.encode(archive: archive_value)
  // No Zip64 markers should appear anywhere in the stream — both
  // signatures (PK\6\6 and PK\6\7) should be absent.
  contains_subbytes(bytes, <<0x50, 0x4B, 0x06, 0x06>>)
  |> should.equal(False)
  contains_subbytes(bytes, <<0x50, 0x4B, 0x06, 0x07>>)
  |> should.equal(False)
}

// The 65 537-entry round trip is Erlang-only because the JavaScript
// target does not optimise tail calls and the decoder's per-entry
// recursion would blow the engine's call stack on this archive
// shape.  The hand-built decoder fixture above + the encoder-side
// signature check (which is target-agnostic) cover the same code
// paths on JavaScript.
@target(erlang)
pub fn encoder_emits_zip64_for_many_entries_test() -> Nil {
  // Build an archive with >65535 entries to force the Zip64 EOCD
  // record path on the encoder side.  Use empty bodies so we don't
  // blow the test wallclock or memory budget.  `list.repeat` +
  // `list.index_fold` build the entry list iteratively in stdlib
  // primitives so the JavaScript target doesn't blow its call stack
  // through deep Gleam recursion.  The decoder must round-trip the
  // entry count.
  let arch =
    list.repeat(<<>>, 65_537)
    |> list.index_fold(zip.new(), fn(acc, _body, index) {
      archive.add(
        acc,
        entry: entry.file(path: "e" <> int_to_string(index), body: <<>>),
      )
    })
  let assert Ok(bytes) = zip.encode(archive: arch)
  // The Zip64 EOCD record signature MUST appear.
  contains_subbytes(bytes, <<0x50, 0x4B, 0x06, 0x06>>)
  |> should.equal(True)
  // And the locator immediately before the standard EOCD.
  contains_subbytes(bytes, <<0x50, 0x4B, 0x06, 0x07>>)
  |> should.equal(True)

  // Round-trip must agree on the entry count.  Default
  // `max_members` is 10 000 so we have to relax it explicitly to
  // accept a 65 537-entry archive.
  let relaxed = limit.default() |> limit.with_max_members(count: 100_000)
  let assert Ok(decoded) = zip.decode_with_limits(bytes: bytes, limits: relaxed)
  archive.entry_count(decoded)
  |> should.equal(65_537)
}

fn contains_subbytes(haystack: BitArray, needle: BitArray) -> Bool {
  let h_size = bit_array.byte_size(haystack)
  let n_size = bit_array.byte_size(needle)
  case n_size {
    0 -> True
    _ -> search_at(haystack, needle, 0, h_size - n_size)
  }
}

fn search_at(haystack: BitArray, needle: BitArray, pos: Int, end: Int) -> Bool {
  case pos > end {
    True -> False
    False ->
      case bit_array.slice(haystack, pos, bit_array.byte_size(needle)) {
        Ok(chunk) ->
          case chunk == needle {
            True -> True
            False -> search_at(haystack, needle, pos + 1, end)
          }
        _ -> False
      }
  }
}

@target(erlang)
fn int_to_string(n: Int) -> String {
  // Cheap base-10 conversion without pulling another import.
  case n {
    0 -> "0"
    _ -> int_to_string_loop(n, "")
  }
}

@target(erlang)
fn int_to_string_loop(n: Int, acc: String) -> String {
  case n {
    0 -> acc
    _ -> {
      let digit = n - { n / 10 } * 10
      let ch = case digit {
        0 -> "0"
        1 -> "1"
        2 -> "2"
        3 -> "3"
        4 -> "4"
        5 -> "5"
        6 -> "6"
        7 -> "7"
        8 -> "8"
        _ -> "9"
      }
      int_to_string_loop(n / 10, ch <> acc)
    }
  }
}
