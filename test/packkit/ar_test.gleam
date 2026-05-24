import gleam/bit_array
import gleam/list
import gleeunit/should
import packkit/ar
import packkit/archive
import packkit/entry
import packkit/error

pub fn roundtrip_file_test() -> Nil {
  let original =
    ar.new()
    |> archive_add_file("a.o", <<1, 2, 3>>)
    |> archive_add_file("b.o", <<4, 5, 6, 7>>)

  let assert Ok(bytes) = ar.encode(archive: original)
  let assert Ok(decoded) = ar.decode(bytes: bytes)

  list.map(archive.entries(decoded), fn(e) {
    #(entry.to_string(entry.path(e)), entry.body(e))
  })
  |> should.equal([#("a.o", <<1, 2, 3>>), #("b.o", <<4, 5, 6, 7>>)])
}

pub fn roundtrip_long_name_test() -> Nil {
  let path = "this-is-a-very-long-object-name-that-overflows-16-bytes.o"
  let body = <<"long-payload":utf8>>

  let original = ar.new() |> archive_add_file(path, body)
  let assert Ok(bytes) = ar.encode(archive: original)
  let assert Ok(decoded) = ar.decode(bytes: bytes)
  let assert [restored] = archive.entries(decoded)

  entry.to_string(entry.path(restored))
  |> should.equal(path)
  entry.body(restored)
  |> should.equal(body)
}

pub fn rejects_directory_entries_test() -> Nil {
  let assert Ok(dir_entry) = entry.directory_checked(path: "build")
  let archive_value =
    archive.new(format: ar.format())
    |> archive.add(entry: dir_entry)

  case ar.encode(archive: archive_value) {
    Error(error.ArchiveEntryRejected(_, _)) -> Nil
    _ -> should.fail()
  }
}

pub fn encoder_rejects_archive_comment_test() -> Nil {
  let with_note =
    ar.new()
    |> archive_add_file("a.o", <<>>)
    |> archive.with_comment(comment: "nope")
  case ar.encode(archive: with_note) {
    Error(error.ArchiveCommentUnsupported(format: "ar")) -> Nil
    _ -> should.fail()
  }
}

pub fn encoder_rejects_uid_overflow_test() -> Nil {
  // The ar uid field is 6 ASCII decimal digits.  999_999 fits;
  // 1_000_000 does not, and used to silently truncate via
  // `right_pad`.
  let assert Ok(base) = entry.file_checked(path: "a.o", body: <<>>)
  let huge = base |> entry.with_owner(user_id: 1_000_000, group_id: 0)
  let archive_value =
    archive.new(format: ar.format()) |> archive.add(entry: huge)
  case ar.encode(archive: archive_value) {
    Error(error.ArchiveFieldOverflow(field: "ar uid", value: 1_000_000, max: _)) ->
      Nil
    _ -> should.fail()
  }
}

pub fn encoder_accepts_uid_boundary_test() -> Nil {
  let assert Ok(base) = entry.file_checked(path: "a.o", body: <<>>)
  let max_uid = base |> entry.with_owner(user_id: 999_999, group_id: 0)
  let archive_value =
    archive.new(format: ar.format()) |> archive.add(entry: max_uid)
  case ar.encode(archive: archive_value) {
    Ok(_) -> Nil
    _ -> should.fail()
  }
}

pub fn decodes_gnu_long_name_string_table_test() -> Nil {
  // Build the GNU long-name form by hand.  The string table member
  // is named `//` and holds NUL-/`/`-terminated long names; regular
  // entry headers then carry `/<offset>` references into the table.
  //
  // Layout (16-byte name field, padded with spaces):
  //   `//              ` 0 0 0 0 <table_size>  table body
  //   `/0              ` 1750000000 0 0 644 4   `DATA`
  //   `/<offset>       ` 1750000000 0 0 644 4   `MORE`

  let long_a = "this-is-a-very-long-archive-member-name.o"
  let long_b = "another-equally-long-archive-member.o"
  // GNU writes "<name>/\n" sequences in the table.
  let table_body = bit_array.from_string(long_a <> "/\n" <> long_b <> "/\n")
  let table_size = bit_array.byte_size(table_body)
  let table_size_padded = case table_size % 2 {
    0 -> table_body
    _ -> bit_array.concat([table_body, <<0x0A>>])
  }

  let offset_b = string_byte_size(long_a) + 2

  let stream =
    bit_array.concat([
      bit_array.from_string("!<arch>\n"),
      ar_header_bits("//", 0, 0, 0, 0, table_size),
      table_size_padded,
      ar_header_bits("/0", 1_750_000_000, 0, 0, 0o644, 4),
      <<"DATA":utf8>>,
      ar_header_bits(
        "/" <> int_to_string(offset_b),
        1_750_000_000,
        0,
        0,
        0o644,
        4,
      ),
      <<"MORE":utf8>>,
    ])

  let assert Ok(decoded) = ar.decode(bytes: stream)

  list.map(archive.entries(decoded), fn(e) {
    #(entry.to_string(entry.path(e)), entry.body(e))
  })
  |> should.equal([
    #(long_a, <<"DATA":utf8>>),
    #(long_b, <<"MORE":utf8>>),
  ])
}

pub fn skips_gnu_symbol_table_member_test() -> Nil {
  // GNU ar normally writes a symbol table member named `/` (with
  // some random body) before any real entries.  The decoder must
  // skip it silently rather than surfacing it as a user entry.
  let symtab_body = <<0x00, 0x00, 0x00, 0x00>>
  let stream =
    bit_array.concat([
      bit_array.from_string("!<arch>\n"),
      ar_header_bits("/", 0, 0, 0, 0, 4),
      symtab_body,
      ar_header_bits("hello.o", 1_750_000_000, 0, 0, 0o644, 5),
      <<"HELLO":utf8>>,
    ])

  let assert Ok(decoded) = ar.decode(bytes: stream)

  list.map(archive.entries(decoded), fn(e) {
    #(entry.to_string(entry.path(e)), entry.body(e))
  })
  |> should.equal([#("hello.o", <<"HELLO":utf8>>)])
}

fn ar_header_bits(
  name: String,
  mtime: Int,
  uid: Int,
  gid: Int,
  mode: Int,
  size: Int,
) -> BitArray {
  bit_array.concat([
    right_pad(bit_array.from_string(name), 16, 0x20),
    right_pad(bit_array.from_string(int_to_string(mtime)), 12, 0x20),
    right_pad(bit_array.from_string(int_to_string(uid)), 6, 0x20),
    right_pad(bit_array.from_string(int_to_string(gid)), 6, 0x20),
    right_pad(bit_array.from_string(int_to_base8(mode)), 8, 0x20),
    right_pad(bit_array.from_string(int_to_string(size)), 10, 0x20),
    <<0x60, 0x0A>>,
  ])
}

fn right_pad(value: BitArray, width: Int, fill: Int) -> BitArray {
  let size = bit_array.byte_size(value)
  case size >= width {
    True -> value
    False -> bit_array.concat([value, byte_repeat(fill, width - size)])
  }
}

fn byte_repeat(byte: Int, count: Int) -> BitArray {
  case count {
    0 -> <<>>
    _ -> <<byte, byte_repeat(byte, count - 1):bits>>
  }
}

fn string_byte_size(value: String) -> Int {
  bit_array.byte_size(bit_array.from_string(value))
}

fn int_to_string(n: Int) -> String {
  case n {
    0 -> "0"
    _ -> int_to_string_loop(n, "")
  }
}

fn int_to_string_loop(n: Int, acc: String) -> String {
  case n {
    0 -> acc
    _ -> {
      let digit = n - { n / 10 } * 10
      int_to_string_loop(n / 10, digit_char(digit) <> acc)
    }
  }
}

fn int_to_base8(n: Int) -> String {
  case n {
    0 -> "0"
    _ -> int_to_base8_loop(n, "")
  }
}

fn int_to_base8_loop(n: Int, acc: String) -> String {
  case n {
    0 -> acc
    _ -> {
      let digit = n - { n / 8 } * 8
      int_to_base8_loop(n / 8, digit_char(digit) <> acc)
    }
  }
}

fn digit_char(n: Int) -> String {
  case n {
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
}

fn archive_add_file(
  archive_value: archive.Archive,
  path: String,
  body: BitArray,
) -> archive.Archive {
  let assert Ok(file_entry) = entry.file_checked(path: path, body: body)
  archive.add(archive_value, entry: file_entry)
}
