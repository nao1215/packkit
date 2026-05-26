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

pub fn decode_with_wrong_password_surfaces_typed_error_test() -> Nil {
  // The AES layer has no MAC, so a wrong password produces garbage
  // plaintext.  The downstream LZMA2 decoder then rejects the garbage
  // with a typed `ArchiveInvalid` — what matters is we don't panic.
  let archive_bytes = fixture_bytes()

  case
    seven_z.decode_with_password(
      bytes: archive_bytes,
      password: "wrong-password",
    )
  {
    Error(_) -> Nil
    Ok(_) -> should.fail()
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
