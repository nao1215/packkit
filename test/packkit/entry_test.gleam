import gleeunit/should
import packkit/entry

pub fn with_mode_checked_accepts_in_range_test() -> Nil {
  let assert Ok(base) = entry.file_checked(path: "a.txt", body: <<>>)
  case entry.with_mode_checked(base, mode: 0o644) {
    Ok(updated) -> {
      entry.mode(entry.metadata(updated))
      |> should.equal(0o644)
    }
    _ -> should.fail()
  }
}

pub fn with_mode_checked_rejects_negative_test() -> Nil {
  let assert Ok(base) = entry.file_checked(path: "a.txt", body: <<>>)
  case entry.with_mode_checked(base, mode: -1) {
    Error(entry.ModeOutOfRange(value: -1)) -> Nil
    _ -> should.fail()
  }
}

pub fn with_mode_checked_rejects_above_16bit_test() -> Nil {
  // Modes outside 0..0xFFFF would overflow the ZIP external-attrs
  // window; reject up-front.
  let assert Ok(base) = entry.file_checked(path: "a.txt", body: <<>>)
  case entry.with_mode_checked(base, mode: 0x1_0000) {
    Error(entry.ModeOutOfRange(value: 0x1_0000)) -> Nil
    _ -> should.fail()
  }
}

pub fn with_owner_checked_rejects_negative_uid_test() -> Nil {
  let assert Ok(base) = entry.file_checked(path: "a.txt", body: <<>>)
  case entry.with_owner_checked(base, user_id: -1, group_id: 0) {
    Error(entry.OwnerOutOfRange(value: -1)) -> Nil
    _ -> should.fail()
  }
}

pub fn with_owner_checked_rejects_negative_gid_test() -> Nil {
  let assert Ok(base) = entry.file_checked(path: "a.txt", body: <<>>)
  case entry.with_owner_checked(base, user_id: 0, group_id: -42) {
    Error(entry.OwnerOutOfRange(value: -42)) -> Nil
    _ -> should.fail()
  }
}

pub fn with_owner_checked_allows_format_specific_overflow_test() -> Nil {
  // Format-side overflow (e.g. tar's 21-bit uid) is enforced later, at
  // encode time, so the entry-level check must let large-but-non-negative
  // values through.
  let assert Ok(base) = entry.file_checked(path: "a.txt", body: <<>>)
  case entry.with_owner_checked(base, user_id: 1_000_000, group_id: 0) {
    Ok(updated) ->
      entry.user_id(entry.metadata(updated))
      |> should.equal(1_000_000)
    _ -> should.fail()
  }
}

pub fn with_modified_at_checked_rejects_negative_test() -> Nil {
  let assert Ok(base) = entry.file_checked(path: "a.txt", body: <<>>)
  case entry.with_modified_at_checked(base, unix_seconds: -1) {
    Error(entry.ModifiedAtOutOfRange(value: -1)) -> Nil
    _ -> should.fail()
  }
}

pub fn with_modified_at_checked_accepts_zero_test() -> Nil {
  let assert Ok(base) = entry.file_checked(path: "a.txt", body: <<>>)
  case entry.with_modified_at_checked(base, unix_seconds: 0) {
    Ok(_) -> Nil
    _ -> should.fail()
  }
}

pub fn entry_kind_is_a_transparent_enum_test() -> Nil {
  // The previously-stringly-typed kind now pattern-matches as a
  // typed enum.  This test pins down the value mapping so future
  // additions get compile-time feedback when callers forget a case.
  let assert Ok(file_e) = entry.file_checked(path: "f", body: <<>>)
  let assert Ok(dir_e) = entry.directory_checked(path: "d")
  let assert Ok(sym_e) = entry.symlink_checked(path: "s", target: "t")
  let assert Ok(hard_e) = entry.hardlink_checked(path: "h", target: "t")
  entry.kind(file_e) |> should.equal(entry.File)
  entry.kind(dir_e) |> should.equal(entry.Directory)
  entry.kind(sym_e) |> should.equal(entry.Symlink)
  entry.kind(hard_e) |> should.equal(entry.Hardlink)
}

pub fn is_kind_predicates_match_kind_test() -> Nil {
  // The four `is_*` helpers are short-circuits over `kind(entry) ==
  // <variant>`; assert every kind triggers exactly the matching
  // predicate and nothing else, so adding a new EntryKind doesn't
  // silently break the contract.
  let assert Ok(file_e) = entry.file_checked(path: "f", body: <<>>)
  let assert Ok(dir_e) = entry.directory_checked(path: "d")
  let assert Ok(sym_e) = entry.symlink_checked(path: "s", target: "t")
  let assert Ok(hard_e) = entry.hardlink_checked(path: "h", target: "t")

  entry.is_file(file_e) |> should.be_true
  entry.is_directory(file_e) |> should.be_false
  entry.is_symlink(file_e) |> should.be_false
  entry.is_hardlink(file_e) |> should.be_false

  entry.is_file(dir_e) |> should.be_false
  entry.is_directory(dir_e) |> should.be_true
  entry.is_symlink(dir_e) |> should.be_false
  entry.is_hardlink(dir_e) |> should.be_false

  entry.is_file(sym_e) |> should.be_false
  entry.is_directory(sym_e) |> should.be_false
  entry.is_symlink(sym_e) |> should.be_true
  entry.is_hardlink(sym_e) |> should.be_false

  entry.is_file(hard_e) |> should.be_false
  entry.is_directory(hard_e) |> should.be_false
  entry.is_symlink(hard_e) |> should.be_false
  entry.is_hardlink(hard_e) |> should.be_true
}
