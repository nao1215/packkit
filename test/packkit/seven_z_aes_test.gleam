//// 7z AES (`06 F1 07 01`) decryption tests.
////
//// The fixture is the byte-for-byte output of:
////   echo "secret payload for 7z AES test" > secret.txt
////   7z a -phunter2 secret.7z secret.txt
//// (p7zip 23.01).  This pins the SHA-256 KDF + AES-256-CBC chain
//// against what the reference encoder produces — wrong S-box, wrong
//// IV handling, wrong CBC direction, or a wrong UTF-16LE encoding
//// of the password all flip the decrypted plaintext.

import gleam/list
import gleam/string
import gleeunit/should
import packkit/archive as archives
import packkit/entry
import packkit/error
import packkit/seven_z

const secret_password: String = "hunter2"

const expected_member_name: String = "secret.txt"

const expected_member_contents: String = "secret payload for 7z AES test\n"

pub fn decode_with_password_round_trip_test() -> Nil {
  // Reads the fixture, decrypts the AES + LZMA2 chain, and confirms
  // the single member name + body match what was packed.  This is the
  // canonical "wrong anywhere ⇒ test fails" check.
  let archive_bytes = fixture_bytes()

  let assert Ok(archive) =
    seven_z.decode_with_password(
      bytes: archive_bytes,
      password: secret_password,
    )

  let members = archives.entries(archive)
  list.length(members) |> should.equal(1)

  let assert [member] = members
  member |> entry.path |> entry.to_string |> should.equal(expected_member_name)
  member |> entry.body |> should.equal(<<expected_member_contents:utf8>>)
}

pub fn decode_without_password_rejects_aes_folder_test() -> Nil {
  // Calling the no-password `decode` on an AES-encrypted archive must
  // surface a typed `ArchiveInvalid` (not a panic) explaining that a
  // password is required.
  let archive_bytes = fixture_bytes()

  case seven_z.decode(bytes: archive_bytes) {
    Error(error.ArchiveInvalid(message: message)) ->
      // The exact wording is not contractual, but the message MUST
      // mention `decode_with_password` so callers know how to fix it.
      message
      |> string.contains("decode_with_password")
      |> should.equal(True)
    _ -> should.fail()
  }
}

pub fn decode_with_password_header_encryption_round_trip_test() -> Nil {
  // Header-encryption fixture from `7z a -phunter2 -mhe=on
  // secret_he.7z secret.txt`.  Forces the encoded-next-header path
  // (NID 0x17) through the AES coder chain, which means the *folder
  // descriptions* themselves are wrapped in AES — so the password
  // has to be threaded into `decode_encoded_header`, not just into
  // the post-header folder decode.
  let archive_bytes = fixture_bytes_header_encrypted()

  let assert Ok(archive) =
    seven_z.decode_with_password(
      bytes: archive_bytes,
      password: secret_password,
    )

  let members = archives.entries(archive)
  list.length(members) |> should.equal(1)

  let assert [member] = members
  member |> entry.path |> entry.to_string |> should.equal(expected_member_name)
  member
  |> entry.body
  |> should.equal(<<"secret payload behind encrypted header\n":utf8>>)
}

pub fn decode_without_password_rejects_header_encryption_test() -> Nil {
  // Same fixture, but called via the no-password `decode` — must
  // surface a typed `ArchiveInvalid` rather than panicking on the
  // encrypted next-header bytes.
  let archive_bytes = fixture_bytes_header_encrypted()

  case seven_z.decode(bytes: archive_bytes) {
    Ok(_) -> should.fail()
    _ -> Nil
  }
}

// -- encoder round-trips --------------------------------------------
//
// The encoder uses a deterministic IV / salt (see
// `seven_z.encode_with_password`'s docstring), so the encrypt → decrypt
// round-trip is the canonical "does the chain compose correctly" test.

pub fn encode_with_password_round_trip_test() -> Nil {
  let archive =
    archives.new(format: seven_z.format())
    |> archives.add(
      entry: entry.file(path: "hello.txt", body: <<
        "hello, encrypted seven_z\n":utf8,
      >>),
    )

  let assert Ok(encoded) =
    seven_z.encode_with_password(archive: archive, password: secret_password)

  let assert Ok(decoded) =
    seven_z.decode_with_password(bytes: encoded, password: secret_password)

  let members = archives.entries(decoded)
  list.length(members) |> should.equal(1)

  let assert [member] = members
  member |> entry.path |> entry.to_string |> should.equal("hello.txt")
  member |> entry.body |> should.equal(<<"hello, encrypted seven_z\n":utf8>>)
}

pub fn encode_with_password_and_method_copy_round_trip_test() -> Nil {
  // Verifies the 2-coder chain wiring for a non-LZMA inner method:
  // [AES, Copy] should still round-trip, exercising the case where
  // AES output IS the final bodies (no compression in between).
  let archive =
    archives.new(format: seven_z.format())
    |> archives.add(
      entry: entry.file(path: "raw.bin", body: <<
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        11,
        12,
        13,
        14,
        15,
        16,
        17,
        18,
      >>),
    )

  let assert Ok(encoded) =
    seven_z.encode_with_password_and_method(
      archive: archive,
      password: secret_password,
      method: seven_z.copy(),
    )

  let assert Ok(decoded) =
    seven_z.decode_with_password(bytes: encoded, password: secret_password)

  let assert [member] = archives.entries(decoded)
  member
  |> entry.body
  |> should.equal(<<
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
  >>)
}

pub fn encode_with_password_is_deterministic_test() -> Nil {
  // With empty salt + zero IV + a fixed numCyclesPower, two encodes
  // of the same archive must produce byte-identical archives.  This
  // pins the "no hidden randomness" property the docstring promises.
  let archive =
    archives.new(format: seven_z.format())
    |> archives.add(
      entry: entry.file(path: "a.txt", body: <<
        "deterministic encoder body\n":utf8,
      >>),
    )

  let assert Ok(first) =
    seven_z.encode_with_password(archive: archive, password: secret_password)
  let assert Ok(second) =
    seven_z.encode_with_password(archive: archive, password: secret_password)

  first |> should.equal(second)
}

pub fn encode_with_header_encryption_round_trip_test() -> Nil {
  // `-mhe=on` equivalent: both the payload AND the next header are
  // AES-encrypted.  Round-trip through `decode_with_password` (which
  // forwards the password into `decode_encoded_header`) must recover
  // the original entries.
  let archive =
    archives.new(format: seven_z.format())
    |> archives.add(
      entry: entry.file(path: "ledger.txt", body: <<
        "header-encrypted entry body\n":utf8,
      >>),
    )

  let assert Ok(encoded) =
    seven_z.encode_with_password_and_header_encryption(
      archive: archive,
      password: secret_password,
    )

  let assert Ok(decoded) =
    seven_z.decode_with_password(bytes: encoded, password: secret_password)

  let assert [member] = archives.entries(decoded)
  member |> entry.path |> entry.to_string |> should.equal("ledger.txt")
  member |> entry.body |> should.equal(<<"header-encrypted entry body\n":utf8>>)
}

pub fn encode_with_header_encryption_emits_nid_17_test() -> Nil {
  // The header-encryption encoder must point the signature header at
  // an `nid_encoded_header (0x17)` block — that's the on-disk marker
  // for `-mhe=on`.  We can read the next-header start byte directly
  // from the archive without involving a decoder.
  let archive =
    archives.new(format: seven_z.format())
    |> archives.add(entry: entry.file(path: "x.txt", body: <<"hello":utf8>>))

  let assert Ok(encoded) =
    seven_z.encode_with_password_and_header_encryption(
      archive: archive,
      password: secret_password,
    )

  // Signature header bytes 12..19 hold the little-endian 64-bit
  // offset of the next header from the end of the signature header.
  let assert <<_:bytes-size(12), next_offset:little-size(64), _:bytes>> =
    encoded
  let next_header_start = 32 + next_offset
  // Skip to that offset and read the first byte — it must be 0x17.
  let assert <<_:bytes-size(next_header_start), first_byte, _:bytes>> = encoded
  first_byte |> should.equal(0x17)
}

pub fn encode_with_password_decode_wrong_password_test() -> Nil {
  let archive =
    archives.new(format: seven_z.format())
    |> archives.add(
      entry: entry.file(path: "x.txt", body: <<"some content":utf8>>),
    )

  let assert Ok(encoded) =
    seven_z.encode_with_password(archive: archive, password: secret_password)

  case seven_z.decode_with_password(bytes: encoded, password: "wrong") {
    Ok(_) -> should.fail()
    _ -> Nil
  }
}

pub fn decode_with_wrong_password_surfaces_typed_error_test() -> Nil {
  // The AES layer has no MAC, so a wrong password produces garbage
  // plaintext.  The downstream LZMA2 decoder then rejects the garbage
  // with a typed `ArchiveInvalid` — what matters is we don't panic.
  let archive_bytes = fixture_bytes()

  let outcome =
    seven_z.decode_with_password(
      bytes: archive_bytes,
      password: "wrong-password",
    )

  // We only care that the outcome is `Error(_)`; the specific typed
  // error varies (LZMA2 usually surfaces ArchiveInvalid, but the
  // codec layer is free to pick a sharper error in future).
  case outcome {
    Ok(_) -> should.fail()
    _ -> Nil
  }
}

// -- helpers --------------------------------------------------------

// The 194-byte fixture from `7z a -phunter2 secret.7z secret.txt`.
fn fixture_bytes() -> BitArray {
  <<
    0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00, 0x04, 0x10, 0x25, 0x04, 0x2A, 0x30,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x72, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x9E, 0x0C, 0x40, 0xF8, 0x4A, 0xAE, 0x68, 0x6C, 0x4F, 0x9F, 0xBB,
    0xD6, 0xED, 0xC2, 0xAC, 0x8C, 0x1B, 0x8F, 0xC7, 0x5B, 0xD5, 0xCE, 0x84, 0xB0,
    0xDF, 0x66, 0x2D, 0x39, 0x43, 0xE2, 0xCB, 0x47, 0xF7, 0xFB, 0x5A, 0xFD, 0x06,
    0xD1, 0x49, 0x1B, 0xF3, 0x5F, 0xFD, 0xD3, 0x53, 0xD6, 0x86, 0x65, 0xD0, 0xB4,
    0x11, 0x36, 0x01, 0x04, 0x06, 0x00, 0x01, 0x09, 0x30, 0x00, 0x07, 0x0B, 0x01,
    0x00, 0x02, 0x24, 0x06, 0xF1, 0x07, 0x01, 0x12, 0x53, 0x0F, 0xA2, 0xBF, 0xED,
    0x09, 0x02, 0x0C, 0x81, 0xC7, 0x90, 0x57, 0xE6, 0xB2, 0x1D, 0x54, 0x33, 0x04,
    0x21, 0x21, 0x01, 0x00, 0x01, 0x00, 0x0C, 0x23, 0x1F, 0x00, 0x08, 0x0A, 0x01,
    0x81, 0x0A, 0x7D, 0x34, 0x00, 0x00, 0x05, 0x01, 0x19, 0x01, 0x00, 0x11, 0x17,
    0x00, 0x73, 0x00, 0x65, 0x00, 0x63, 0x00, 0x72, 0x00, 0x65, 0x00, 0x74, 0x00,
    0x2E, 0x00, 0x74, 0x00, 0x78, 0x00, 0x74, 0x00, 0x00, 0x00, 0x19, 0x04, 0x00,
    0x00, 0x00, 0x00, 0x14, 0x0A, 0x01, 0x00, 0x6B, 0x89, 0x21, 0xB7, 0xCE, 0xEC,
    0xDC, 0x01, 0x15, 0x06, 0x01, 0x00, 0x20, 0x80, 0xA4, 0x81, 0x00, 0x00,
  >>
}

// The 255-byte fixture from `7z a -phunter2 -mhe=on secret_he.7z
// secret.txt`.  The next header itself is AES-encrypted; the
// signature-header still points at it via the usual offset / size.
fn fixture_bytes_header_encrypted() -> BitArray {
  <<
    0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00, 0x04, 0x75, 0x6F, 0xCB, 0xD2, 0xB0,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2F, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x09, 0x35, 0x86, 0x1C, 0x2A, 0x81, 0xA3, 0x51, 0x9D, 0xDD, 0x44,
    0x01, 0xB2, 0xC4, 0x05, 0xA1, 0xC7, 0x36, 0xDF, 0xA9, 0x00, 0xBB, 0xD4, 0x99,
    0xF2, 0xE0, 0xF9, 0xB3, 0xD4, 0xD9, 0x0F, 0xAA, 0xB7, 0x9A, 0x4B, 0x59, 0x75,
    0x1C, 0xBF, 0x22, 0x36, 0x94, 0xC9, 0x31, 0x1C, 0x71, 0xB6, 0xA2, 0x51, 0x4C,
    0x7B, 0x52, 0xCF, 0xBF, 0x04, 0xC5, 0x5A, 0x87, 0x0A, 0x06, 0xFF, 0x9E, 0xC5,
    0xFF, 0xFA, 0xCF, 0x80, 0x36, 0x96, 0xB5, 0x25, 0xCF, 0x6B, 0xF6, 0x8B, 0xC4,
    0x35, 0x6B, 0x19, 0xB8, 0xB2, 0x1A, 0xF7, 0x8F, 0xC5, 0xA3, 0x1A, 0xCA, 0x01,
    0x0A, 0x2E, 0xE2, 0xAD, 0x4F, 0x47, 0x46, 0x5D, 0x8E, 0xF3, 0xF2, 0x31, 0xE8,
    0x8C, 0x5C, 0x5B, 0xF4, 0x2A, 0x85, 0xAA, 0xDE, 0x83, 0x84, 0x58, 0x05, 0x9C,
    0x3D, 0x53, 0xFE, 0x77, 0x74, 0xFD, 0x27, 0xA1, 0x78, 0xC6, 0x1A, 0x73, 0x90,
    0xB3, 0xE6, 0xC8, 0x69, 0xCC, 0x37, 0xF3, 0x7E, 0xF3, 0xC0, 0xE0, 0xCC, 0x30,
    0x60, 0x40, 0x3B, 0x10, 0xC1, 0x20, 0xE9, 0x93, 0x1A, 0x53, 0xA7, 0x94, 0xB4,
    0x18, 0x36, 0xB3, 0x94, 0xFC, 0x37, 0x59, 0xAA, 0xEC, 0x1B, 0x89, 0x5B, 0x93,
    0x47, 0xF7, 0xC8, 0xE2, 0x73, 0xFB, 0x2E, 0xFD, 0xB9, 0x05, 0x89, 0x77, 0xCB,
    0x17, 0x06, 0x30, 0x01, 0x09, 0x80, 0x80, 0x00, 0x07, 0x0B, 0x01, 0x00, 0x01,
    0x24, 0x06, 0xF1, 0x07, 0x01, 0x12, 0x53, 0x0F, 0xD9, 0x20, 0xE0, 0x90, 0x45,
    0x1F, 0x6B, 0xF1, 0xB5, 0x1A, 0x4C, 0x56, 0x4C, 0x5C, 0xA2, 0x0E, 0x0C, 0x72,
    0x0A, 0x01, 0xCE, 0xC1, 0x30, 0x99, 0x00, 0x00,
  >>
}
