//// Hand-made headers whose length fields are negative, larger than the
//// input or inconsistent with each other. Each reader must return
//// `InvalidData` without panicking or looping.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/string
import packkit
import packkit/archive

fn field(text: String, width: Int) -> BitArray {
  bit_array.from_string(string.pad_end(text, to: width, with: " "))
}

fn ar_member(name: String, size: String, payload: BitArray) -> BitArray {
  <<
    field(name, 16):bits,
    field("0", 12):bits,
    field("0", 6):bits,
    field("0", 6):bits,
    field("644", 8):bits,
    field(size, 10):bits,
    "`\n",
    payload:bits,
  >>
}

fn read_ar(members: BitArray) -> Result(archive.Archive, archive.ArchiveError) {
  packkit.read(<<"!<arch>\n", members:bits>>, format: archive.Ar)
}

fn is_invalid(result: Result(a, archive.ArchiveError)) -> Bool {
  case result {
    Error(archive.InvalidData(_)) -> True
    _ -> False
  }
}

pub fn ar_negative_symbol_table_size_is_invalid_test() -> Nil {
  // A size of -60 makes the member zero bytes long, so a reader that
  // trusts it never moves forward.
  assert is_invalid(read_ar(ar_member("/", "-60", <<>>)))
}

pub fn ar_negative_member_size_is_invalid_test() -> Nil {
  assert is_invalid(read_ar(ar_member("a.txt", "-1", <<"x">>)))
}

pub fn ar_bsd_name_longer_than_member_is_invalid_test() -> Nil {
  // The name takes 20 bytes but the whole member is 5 bytes.
  let name = <<"abcdefghijklmnopqrst">>
  assert is_invalid(read_ar(ar_member("#1/20", "5", name)))
}

pub fn ar_negative_bsd_name_length_is_invalid_test() -> Nil {
  assert is_invalid(read_ar(ar_member("#1/-5", "5", <<"hello">>)))
}

pub fn ar_negative_gnu_name_offset_is_invalid_test() -> Nil {
  let table = ar_member("//", "6", <<"a.txt/">>)
  assert is_invalid(
    read_ar(<<table:bits, ar_member("/-1", "1", <<"x">>):bits>>),
  )
}

fn hex8(value: Int) -> BitArray {
  bit_array.from_string(string.pad_start(int.to_base16(value), to: 8, with: "0"))
}

fn cpio_header(mode: Int, filesize: Int, namesize: Int) -> BitArray {
  <<
    "070701",
    hex8(0):bits,
    hex8(mode):bits,
    hex8(0):bits,
    hex8(0):bits,
    hex8(1):bits,
    hex8(0):bits,
    hex8(filesize):bits,
    hex8(0):bits,
    hex8(0):bits,
    hex8(0):bits,
    hex8(0):bits,
    hex8(namesize):bits,
    hex8(0):bits,
  >>
}

pub fn cpio_name_size_past_the_input_is_invalid_test() -> Nil {
  let bytes = <<cpio_header(0o100644, 0, 0xFFFFFFFF):bits, "a.txt", 0>>
  assert is_invalid(packkit.read(bytes, format: archive.Cpio))
}

pub fn cpio_body_without_padding_or_trailer_is_invalid_test() -> Nil {
  // 110-byte header plus "a.txt\0" is 116 bytes, already aligned; the
  // one-byte body needs three bytes of padding that are missing.
  let bytes = <<cpio_header(0o100644, 1, 6):bits, "a.txt", 0, "x">>
  assert is_invalid(packkit.read(bytes, format: archive.Cpio))
}

pub fn cpio_body_size_past_the_input_is_invalid_test() -> Nil {
  let bytes = <<cpio_header(0o100644, 0xFFFFFFFF, 6):bits, "a.txt", 0, "x">>
  assert is_invalid(packkit.read(bytes, format: archive.Cpio))
}

fn tar_header(name: String, typeflag: Int, size: Int) -> BitArray {
  let size_field =
    bit_array.from_string(string.pad_start(
      int.to_base8(size),
      to: 11,
      with: "0",
    ))
  let before = <<
    { bit_array.from_string(name) |> pad(100) }:bits,
    "0000644",
    0,
    "0000000",
    0,
    "0000000",
    0,
    size_field:bits,
    0,
    "00000000000",
    0,
  >>
  let after = <<
    typeflag,
    pad(<<>>, 100):bits,
    "ustar",
    0,
    "00",
    pad(<<>>, 247):bits,
  >>
  let sum = byte_sum(<<before:bits, "        ", after:bits>>, 0)
  let checksum =
    bit_array.from_string(string.pad_start(int.to_base8(sum), to: 6, with: "0"))
  <<before:bits, checksum:bits, 0, " ", after:bits>>
}

fn pad(bytes: BitArray, width: Int) -> BitArray {
  <<
    bytes:bits,
    { string.repeat("\u{0}", width - bit_array.byte_size(bytes)) }:utf8,
  >>
}

fn byte_sum(bytes: BitArray, acc: Int) -> Int {
  case bytes {
    <<byte, rest:bytes>> -> byte_sum(rest, acc + byte)
    _ -> acc
  }
}

fn tar_body(body: BitArray) -> BitArray {
  let size = bit_array.byte_size(body)
  pad(body, { size + 511 } / 512 * 512)
}

pub fn tar_pax_path_counts_bytes_not_characters_test() -> Nil {
  // "16 path=日.txt\n" is 16 bytes but only 14 characters.
  let record = <<"16 path=日.txt\n":utf8>>
  assert bit_array.byte_size(record) == 16
  let bytes = <<
    tar_header("pax", 0x78, 16):bits,
    tar_body(record):bits,
    tar_header("short.txt", 0x30, 2):bits,
    tar_body(<<"hi">>):bits,
    pad(<<>>, 1024):bits,
  >>
  let assert Ok(read) = packkit.read(bytes, format: archive.Tar)
  assert list.map(read.entries, fn(e) { e.path }) == ["日.txt"]
}

pub fn tar_size_past_the_input_is_invalid_test() -> Nil {
  let bytes = <<tar_header("a.txt", 0x30, 0o77777777777):bits, "x">>
  assert is_invalid(packkit.read(bytes, format: archive.Tar))
}

pub fn tar_long_name_size_past_the_input_is_invalid_test() -> Nil {
  let bytes = <<tar_header("././@LongLink", 0x4C, 0o77777777777):bits, "x">>
  assert is_invalid(packkit.read(bytes, format: archive.Tar))
}
