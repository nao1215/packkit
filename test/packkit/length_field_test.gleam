//// Hand-made headers whose length fields are negative, larger than the
//// input or inconsistent with each other. Each reader must return
//// `InvalidData` without panicking or looping.

import gleam/bit_array
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
