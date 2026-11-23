//// Every reader rejects an entry whose path climbs out of the target
//// directory with the same `EntryRejected` error. The writers refuse
//// such paths, so each test writes `zz/a.txt` and patches the bytes to
//// `../a.txt`, fixing the checksums the format keeps.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import packkit
import packkit/archive.{Archive}
import packkit/internal/checksum
import packkit/seven_z

const expected =
  Error(archive.EntryRejected(path: "../a.txt", reason: "path traversal"))

fn sample(format: archive.ArchiveFormat) -> archive.Archive {
  Archive(
    format:,
    entries: [archive.new_entry(path: "zz/a.txt", kind: archive.File(<<"hi">>))],
    comment: None,
  )
}

fn replace_all(bytes: BitArray, from: BitArray, to: BitArray) -> BitArray {
  replace_loop(bytes, from, to, <<>>)
}

fn replace_loop(
  bytes: BitArray,
  from: BitArray,
  to: BitArray,
  acc: BitArray,
) -> BitArray {
  let size = bit_array.byte_size(from)
  case bit_array.slice(bytes, 0, size) {
    Ok(head) if head == from -> {
      let assert Ok(rest) =
        bit_array.slice(bytes, size, bit_array.byte_size(bytes) - size)
      replace_loop(rest, from, to, <<acc:bits, to:bits>>)
    }
    _ ->
      case bytes {
        <<byte, rest:bytes>> -> replace_loop(rest, from, to, <<acc:bits, byte>>)
        _ -> <<acc:bits, bytes:bits>>
      }
  }
}

fn utf16le(text: String) -> BitArray {
  string.to_utf_codepoints(text)
  |> list.fold(<<>>, fn(acc, cp) {
    <<acc:bits, string.utf_codepoint_to_int(cp):size(16)-little>>
  })
}

pub fn zip_cpio_and_ar_reject_parent_segment_test() -> Nil {
  [archive.Zip, archive.Cpio, archive.Ar]
  |> list.each(fn(format) {
    let assert Ok(bytes) = packkit.write(sample(format))
    let patched = replace_all(bytes, <<"zz/">>, <<"../">>)
    assert packkit.read(patched, format:) == expected
  })
}

pub fn tar_rejects_parent_segment_test() -> Nil {
  let assert Ok(bytes) = packkit.write(sample(archive.Tar))
  let patched = replace_all(bytes, <<"zz/">>, <<"../">>)
  let assert <<
    head:bytes-size(148),
    _:bytes-size(8),
    tail:bytes-size(356),
    rest:bytes,
  >> = patched
  let sum =
    bit_array_sum(<<head:bits, "        ", tail:bits>>, 0)
    |> int.to_base8
    |> string.pad_start(to: 6, with: "0")
  let fixed = <<head:bits, sum:utf8, 0, " ", tail:bits, rest:bits>>
  assert packkit.read(fixed, format: archive.Tar) == expected
}

fn bit_array_sum(bytes: BitArray, acc: Int) -> Int {
  case bytes {
    <<byte, rest:bytes>> -> bit_array_sum(rest, acc + byte)
    _ -> acc
  }
}

pub fn seven_z_rejects_parent_segment_test() -> Nil {
  let assert Ok(bytes) =
    seven_z.encode(
      sample(archive.SevenZ),
      method: seven_z.Copy,
      encryption: seven_z.Unencrypted,
    )
  let assert <<
    signature:bytes-size(8),
    _start_crc:size(32),
    offset:size(32)-little,
    0:size(32),
    size:size(32)-little,
    0:size(32),
    _next_crc:size(32),
    packed:bytes-size(offset),
    header:bytes-size(size),
  >> = bytes
  let header = replace_all(header, utf16le("zz/"), utf16le("../"))
  let start = <<
    offset:size(32)-little,
    0:size(32),
    size:size(32)-little,
    0:size(32),
    { checksum.crc32(data: header) }:size(32)-little,
  >>
  let fixed = <<
    signature:bits,
    { checksum.crc32(data: start) }:size(32)-little,
    start:bits,
    packed:bits,
    header:bits,
  >>
  assert packkit.read(fixed, format: archive.SevenZ) == expected
}
