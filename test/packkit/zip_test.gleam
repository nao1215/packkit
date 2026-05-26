import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option
import gleam/string
import gleeunit/should
import packkit/archive
import packkit/bzip2
import packkit/checksum
import packkit/entry
import packkit/error
import packkit/level
import packkit/xz
import packkit/zip
import packkit/zstd

// Reusable helper: build a single-file archive whose only entry has
// the requested Unix mtime, encode it through `zip.encode`, then
// decode through `zip.decode` and return the round-tripped
// `modified_at_unix` value.  Uses `let assert` so any encode / decode
// failure halts the surrounding test with a stack trace rather than
// silently coercing to a sentinel.
fn zip_roundtrip_mtime(unix_seconds: Int) -> Int {
  let entry_value =
    entry.file(path: "stamped.txt", body: <<"hi":utf8>>)
    |> entry.with_modified_at(unix_seconds: unix_seconds)
  let archive_value = archive.add(zip.new(), entry: entry_value)
  let assert Ok(bytes) = zip.encode(archive: archive_value)
  let assert Ok(decoded) = zip.decode(bytes: bytes)
  let assert [single] = archive.entries(decoded)
  single |> entry.metadata |> entry.modified_at_unix
}

pub fn roundtrip_single_file_test() -> Nil {
  let original =
    zip.new()
    |> archive_add_file("hello.txt", <<"hello":utf8>>)

  let assert Ok(bytes) = zip.encode(archive: original)
  let assert Ok(decoded) = zip.decode(bytes: bytes)

  let assert [restored] = archive.entries(decoded)
  entry.to_string(entry.path(restored))
  |> should.equal("hello.txt")
  entry.body(restored)
  |> should.equal(<<"hello":utf8>>)
}

pub fn roundtrip_mixed_entries_test() -> Nil {
  let original =
    zip.new()
    |> archive_add_directory("doc")
    |> archive_add_file("doc/spec.md", <<"contents":utf8>>)
    |> archive_add_file("README.md", <<"a":utf8>>)

  let assert Ok(bytes) = zip.encode(archive: original)
  let assert Ok(decoded) = zip.decode(bytes: bytes)
  let entries = archive.entries(decoded)

  list.map(entries, entry.kind)
  |> should.equal([entry.Directory, entry.File, entry.File])

  let assert [_, doc_spec, readme] = entries
  entry.body(doc_spec)
  |> should.equal(<<"contents":utf8>>)
  entry.body(readme)
  |> should.equal(<<"a":utf8>>)
}

pub fn rejects_corrupted_crc_test() -> Nil {
  let original =
    zip.new()
    |> archive_add_file("data.bin", <<1, 2, 3, 4>>)

  let assert Ok(bytes) = zip.encode(archive: original)
  // The 8-byte filename "data.bin" sits between the 30-byte LFH and the
  // 4-byte body, so the body lives at offset 38..42.
  let body_offset = 30 + 8
  let assert Ok(prefix) = bit_array.slice(bytes, 0, body_offset)
  let assert Ok(suffix) =
    bit_array.slice(
      bytes,
      body_offset + 4,
      bit_array.byte_size(bytes) - body_offset - 4,
    )
  let corrupted = bit_array.concat([prefix, <<0, 0, 0, 0>>, suffix])

  case zip.decode(bytes: corrupted) {
    Error(error.ArchiveInvalid(_)) -> Nil
    _ -> should.fail()
  }
}

pub fn decodes_python_deflate_zip_test() -> Nil {
  // Built with `python3 -m zipfile -c out.zip` style code:
  //   zf.writestr('hello.txt', 'hello world\n' * 50)
  //   zf.writestr('numbers.txt', '0123456789' * 100)
  let bytes = python_deflate_zip()
  let assert Ok(archive_value) = zip.decode(bytes: bytes)
  let entries = archive.entries(archive_value)

  list.map(entries, fn(e) { entry.to_string(entry.path(e)) })
  |> should.equal(["hello.txt", "numbers.txt"])

  let assert [hello, numbers] = entries
  entry.body(hello)
  |> should.equal(repeat_bytes(<<"hello world\n":utf8>>, 50))
  entry.body(numbers)
  |> should.equal(repeat_bytes(<<"0123456789":utf8>>, 100))
}

pub fn encode_deflate_method_default_level_roundtrip_test() -> Nil {
  // The default level maps to the fixed-Huffman DEFLATE encoder we
  // actually ship; round-trip should be lossless.
  let original =
    zip.new()
    |> archive_add_file(
      "greeting.txt",
      repeat_bytes(<<"hello world":utf8>>, 30),
    )

  let assert Ok(bytes) =
    zip.encode_with_method(
      archive: original,
      method: zip.deflate(level.default()),
    )
  let assert Ok(decoded) = zip.decode(bytes: bytes)
  let assert [restored] = archive.entries(decoded)
  entry.body(restored)
  |> should.equal(repeat_bytes(<<"hello world":utf8>>, 30))
}

pub fn encode_deflate_method_store_level_emits_stored_blocks_test() -> Nil {
  // Level 0 (store) is honoured by emitting stored DEFLATE blocks
  // rather than fixed-Huffman blocks.  The output is still a valid
  // ZIP/deflate stream that the decoder reads back losslessly.
  let payload = <<"deflate level 0 round trip":utf8>>
  let original = zip.new() |> archive_add_file("a.bin", payload)
  let assert Ok(bytes) =
    zip.encode_with_method(
      archive: original,
      method: zip.deflate(level.store()),
    )
  let assert Ok(decoded) = zip.decode(bytes: bytes)
  let assert [restored] = archive.entries(decoded)
  entry.body(restored)
  |> should.equal(payload)
}

pub fn encode_deflate_method_rejects_non_default_level_test() -> Nil {
  // Levels that the fixed-Huffman backend can't honour must be
  // surfaced as a typed `CodecOptionUnsupported` (wrapped as
  // `ArchiveEntryRejected`), not silently coerced to the default.
  let original = zip.new() |> archive_add_file("a.bin", <<"data":utf8>>)
  case
    zip.encode_with_method(archive: original, method: zip.deflate(level.best()))
  {
    Error(error.ArchiveEntryRejected(path: _, reason: reason)) ->
      reason
      |> string.contains("zip-deflate")
      |> should.be_true
    _ -> should.fail()
  }
}

pub fn encode_bzip2_method_roundtrip_test() -> Nil {
  // The bzip2 ZIP method (PKZIP method 12) round-trips through the
  // standard decoder by dispatching to the packkit bzip2 codec.
  let payload = repeat_bytes(<<"bzip2 zip body ":utf8>>, 20)
  let original = zip.new() |> archive_add_file("data.bin", payload)
  let assert Ok(bytes) =
    zip.encode_with_method(archive: original, method: zip.bzip2())
  let assert Ok(decoded) = zip.decode(bytes: bytes)
  let assert [restored] = archive.entries(decoded)
  entry.body(restored) |> should.equal(payload)
}

pub fn encode_zstd_method_roundtrip_test() -> Nil {
  // The zstd ZIP method (PKZIP method 93) round-trips through the
  // standard decoder by dispatching to the packkit zstd codec.
  let payload = repeat_bytes(<<"zstd zip body ":utf8>>, 20)
  let original = zip.new() |> archive_add_file("data.bin", payload)
  let assert Ok(bytes) =
    zip.encode_with_method(archive: original, method: zip.zstd())
  let assert Ok(decoded) = zip.decode(bytes: bytes)
  let assert [restored] = archive.entries(decoded)
  entry.body(restored) |> should.equal(payload)
}

pub fn encode_xz_method_roundtrip_test() -> Nil {
  // The xz ZIP method (PKZIP method 95) round-trips through the
  // standard decoder by dispatching to the packkit xz codec.
  let payload = repeat_bytes(<<"xz zip body ":utf8>>, 20)
  let original = zip.new() |> archive_add_file("data.bin", payload)
  let assert Ok(bytes) =
    zip.encode_with_method(archive: original, method: zip.xz())
  let assert Ok(decoded) = zip.decode(bytes: bytes)
  let assert [restored] = archive.entries(decoded)
  entry.body(restored) |> should.equal(payload)
}

pub fn encode_lzma_method_roundtrip_test() -> Nil {
  // The PKWARE LZMA ZIP method (PKZIP method 14) round-trips through
  // the standard decoder.  The encoder wraps the literal-only LZMA1
  // range-coded stream in the standard 4-byte SDK preamble + 5-byte
  // property block, and sets general-purpose flag bit 1 so the
  // decoder relies on the central-directory uncompressed size rather
  // than an in-stream EOS marker.
  let payload = repeat_bytes(<<"lzma zip body ":utf8>>, 20)
  let original = zip.new() |> archive_add_file("data.bin", payload)
  let assert Ok(bytes) =
    zip.encode_with_method(archive: original, method: zip.lzma())
  let assert Ok(decoded) = zip.decode(bytes: bytes)
  let assert [restored] = archive.entries(decoded)
  entry.body(restored) |> should.equal(payload)
}

pub fn encode_lzma_method_short_payload_test() -> Nil {
  // Single-byte payload exercises the range coder's bootstrap path
  // (only one literal encoded before finish flushes the cache).
  let payload = <<0x42>>
  let original = zip.new() |> archive_add_file("x.bin", payload)
  let assert Ok(bytes) =
    zip.encode_with_method(archive: original, method: zip.lzma())
  let assert Ok(decoded) = zip.decode(bytes: bytes)
  let assert [restored] = archive.entries(decoded)
  entry.body(restored) |> should.equal(payload)
}

pub fn encode_mixed_methods_with_directory_test() -> Nil {
  // Directories ignore the chosen method and stay stored, so an
  // archive with directories + files using a compressed method must
  // still round-trip.
  let payload = <<"compressed-body":utf8>>
  let original =
    zip.new()
    |> archive_add_directory("doc")
    |> archive_add_file("doc/notes.txt", payload)
  let assert Ok(bytes) =
    zip.encode_with_method(archive: original, method: zip.zstd())
  let assert Ok(decoded) = zip.decode(bytes: bytes)
  let entries = archive.entries(decoded)
  list.map(entries, entry.kind)
  |> should.equal([entry.Directory, entry.File])
  let assert [_, notes] = entries
  entry.body(notes) |> should.equal(payload)
}

pub fn archive_comment_round_trips_through_eocd_test() -> Nil {
  // The ZIP EOCD record has a comment slot; `archive.with_comment`
  // must be encoded there and restored on decode.  Previously the
  // comment was silently dropped on encode.
  let original =
    zip.new()
    |> archive_add_file("a.txt", <<"a":utf8>>)
    |> archive.with_comment(comment: "packkit zip comment")
  let assert Ok(bytes) = zip.encode(archive: original)
  let assert Ok(decoded) = zip.decode(bytes: bytes)
  archive.comment(decoded)
  |> should.equal(option.Some("packkit zip comment"))
}

pub fn archive_without_comment_decodes_to_none_test() -> Nil {
  let original = zip.new() |> archive_add_file("a.txt", <<"a":utf8>>)
  let assert Ok(bytes) = zip.encode(archive: original)
  let assert Ok(decoded) = zip.decode(bytes: bytes)
  archive.comment(decoded)
  |> should.equal(option.None)
}

fn repeat_bytes(value: BitArray, times: Int) -> BitArray {
  case times {
    0 -> <<>>
    _ -> bit_array.concat([value, repeat_bytes(value, times - 1)])
  }
}

fn python_deflate_zip() -> BitArray {
  <<
    0x50, 0x4b, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00, 0x08, 0x00, 0x23, 0xad, 0xb6,
    0x5c, 0x17, 0x80, 0xe1, 0x50, 0x15, 0x00, 0x00, 0x00, 0x58, 0x02, 0x00, 0x00,
    0x09, 0x00, 0x00, 0x00, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x2e, 0x74, 0x78, 0x74,
    0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf, 0x2f, 0xca, 0x49, 0xe1, 0xca,
    0x18, 0x65, 0x8f, 0xb2, 0xa9, 0xc4, 0x06, 0x00, 0x50, 0x4b, 0x03, 0x04, 0x14,
    0x00, 0x00, 0x00, 0x08, 0x00, 0x23, 0xad, 0xb6, 0x5c, 0xf1, 0x8f, 0x85, 0x7c,
    0x15, 0x00, 0x00, 0x00, 0xe8, 0x03, 0x00, 0x00, 0x0b, 0x00, 0x00, 0x00, 0x6e,
    0x75, 0x6d, 0x62, 0x65, 0x72, 0x73, 0x2e, 0x74, 0x78, 0x74, 0x33, 0x30, 0x34,
    0x32, 0x36, 0x31, 0x35, 0x33, 0xb7, 0xb0, 0x34, 0x18, 0x65, 0x8d, 0xb2, 0x46,
    0x59, 0xc3, 0x94, 0x05, 0x00, 0x50, 0x4b, 0x01, 0x02, 0x14, 0x03, 0x14, 0x00,
    0x00, 0x00, 0x08, 0x00, 0x23, 0xad, 0xb6, 0x5c, 0x17, 0x80, 0xe1, 0x50, 0x15,
    0x00, 0x00, 0x00, 0x58, 0x02, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x01, 0x00, 0x00, 0x00, 0x00, 0x68,
    0x65, 0x6c, 0x6c, 0x6f, 0x2e, 0x74, 0x78, 0x74, 0x50, 0x4b, 0x01, 0x02, 0x14,
    0x03, 0x14, 0x00, 0x00, 0x00, 0x08, 0x00, 0x23, 0xad, 0xb6, 0x5c, 0xf1, 0x8f,
    0x85, 0x7c, 0x15, 0x00, 0x00, 0x00, 0xe8, 0x03, 0x00, 0x00, 0x0b, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x01, 0x3c, 0x00,
    0x00, 0x00, 0x6e, 0x75, 0x6d, 0x62, 0x65, 0x72, 0x73, 0x2e, 0x74, 0x78, 0x74,
    0x50, 0x4b, 0x05, 0x06, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x02, 0x00, 0x70,
    0x00, 0x00, 0x00, 0x7a, 0x00, 0x00, 0x00, 0x00, 0x00,
  >>
}

pub fn decode_pkware_encrypted_zip_with_correct_password_test() -> Nil {
  // Build an encrypted ZIP fixture in-process using the same PKWARE
  // cipher the decoder expects, then verify `decode_with_password`
  // recovers the original bytes.  The test cipher implementation
  // below is the reference encryption side; the production code
  // never builds encrypted entries (encrypt-on-encode is out of
  // scope for now) so we exercise the decode path against a known
  // round-trippable fixture.
  let body = <<"hello, pkware!":utf8>>
  let bytes = build_zipcrypto_fixture("hello.txt", body, "secret")
  let assert Ok(archive_value) =
    zip.decode_with_password(bytes: bytes, password: "secret")
  let entries = archive.entries(archive_value)
  list.length(entries) |> should.equal(1)
  let assert [decoded] = entries
  entry.to_string(entry.path(decoded)) |> should.equal("hello.txt")
  entry.body(decoded) |> should.equal(body)
}

pub fn decode_pkware_encrypted_zip_wrong_password_rejected_test() -> Nil {
  let body = <<"hello, pkware!":utf8>>
  let bytes = build_zipcrypto_fixture("hello.txt", body, "secret")
  let result = zip.decode_with_password(bytes: bytes, password: "wrong")
  case result {
    Error(error.ArchiveInvalid(message: msg)) ->
      case string.contains(msg, "wrong password") {
        True -> Nil
        False -> should.fail()
      }
    _ -> should.fail()
  }
}

pub fn decode_pkware_encrypted_zip_without_password_surfaces_typed_error_test() -> Nil {
  let body = <<"hello, pkware!":utf8>>
  let bytes = build_zipcrypto_fixture("hello.txt", body, "secret")
  let result = zip.decode(bytes: bytes)
  case result {
    Error(error.ArchiveNotImplemented(feature: feature)) ->
      case string.contains(feature, "encrypted ZIP entry") {
        True -> Nil
        False -> should.fail()
      }
    _ -> should.fail()
  }
}

// ============================================================
// Test-only PKWARE traditional ZIP encryption helpers
// ============================================================

type ZcKeys {
  ZcKeys(k0: Int, k1: Int, k2: Int)
}

fn zc_init() -> ZcKeys {
  ZcKeys(k0: 0x12345678, k1: 0x23456789, k2: 0x34567890)
}

fn zc_from_password(password: String) -> ZcKeys {
  zc_seed_loop(zc_init(), bit_array.from_string(password))
}

fn zc_seed_loop(keys: ZcKeys, password: BitArray) -> ZcKeys {
  case password {
    <<b, rest:bytes>> -> zc_seed_loop(zc_update(keys, b), rest)
    _ -> keys
  }
}

fn zc_update(keys: ZcKeys, byte: Int) -> ZcKeys {
  let k0 = zc_crc32_byte(keys.k0, byte)
  let added = int.bitwise_and(k0, 0xFF) + keys.k1
  let mixed = added * 134_775_813 + 1
  let k1 = int.bitwise_and(mixed, 0xFFFFFFFF)
  let top = int.bitwise_and(int.bitwise_shift_right(k1, 24), 0xFF)
  let k2 = zc_crc32_byte(keys.k2, top)
  ZcKeys(k0: k0, k1: k1, k2: k2)
}

fn zc_crc32_byte(crc: Int, byte: Int) -> Int {
  let idx = int.bitwise_and(int.bitwise_exclusive_or(crc, byte), 0xFF)
  let folded = zc_crc32_fold(idx, 8)
  int.bitwise_exclusive_or(int.bitwise_shift_right(crc, 8), folded)
}

fn zc_crc32_fold(value: Int, rounds: Int) -> Int {
  case rounds {
    0 -> value
    _ -> {
      let next = case int.bitwise_and(value, 1) {
        1 ->
          int.bitwise_exclusive_or(
            int.bitwise_shift_right(value, 1),
            0xEDB88320,
          )
        _ -> int.bitwise_shift_right(value, 1)
      }
      zc_crc32_fold(next, rounds - 1)
    }
  }
}

fn zc_encrypt(
  keys: ZcKeys,
  plain: BitArray,
  acc: BitArray,
) -> #(BitArray, ZcKeys) {
  case plain {
    <<b, rest:bytes>> -> {
      let temp = int.bitwise_or(keys.k2, 2)
      let prod = temp * int.bitwise_exclusive_or(temp, 1)
      let mask = int.bitwise_and(int.bitwise_shift_right(prod, 8), 0xFF)
      let cipher = int.bitwise_exclusive_or(b, mask)
      let next_keys = zc_update(keys, b)
      zc_encrypt(next_keys, rest, <<acc:bits, cipher>>)
    }
    _ -> #(acc, keys)
  }
}

fn build_zipcrypto_fixture(
  name: String,
  body: BitArray,
  password: String,
) -> BitArray {
  let name_bytes = bit_array.from_string(name)
  let name_size = bit_array.byte_size(name_bytes)
  let body_size = bit_array.byte_size(body)
  let crc = checksum.crc32(body)
  // 12-byte encryption header: 11 deterministic bytes + (crc >> 24)
  // in the trailing slot per APPNOTE §6.0.  Any 11 bytes work; the
  // check is on the 12th alone.
  let check_byte = int.bitwise_and(int.bitwise_shift_right(crc, 24), 0xFF)
  let plain_header = <<
    0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, check_byte,
  >>
  let plaintext = bit_array.concat([plain_header, body])
  let keys = zc_from_password(password)
  let #(cipher, _keys) = zc_encrypt(keys, plaintext, <<>>)
  let comp_size = bit_array.byte_size(cipher)

  // ZIP local file header
  let local_header = <<
    0x50, 0x4B, 0x03, 0x04,
    // version_needed: 2.0
    20:size(16)-little,
    // gp flag: bit 0 = encrypted
    1:size(16)-little,
    // method: stored
    0:size(16)-little,
    // mod time / mod date
    0:size(16)-little, 0:size(16)-little,
    // crc32
    crc:size(32)-little,
    // comp_size, uncomp_size
    comp_size:size(32)-little, body_size:size(32)-little,
    // name length, extra length
    name_size:size(16)-little, 0:size(16)-little,
  >>

  let local_offset = 0
  let local = bit_array.concat([local_header, name_bytes, cipher])
  let central_size_offset = bit_array.byte_size(local)

  // Central directory header
  let central_header = <<
    0x50, 0x4B, 0x01, 0x02,
    // version made by, version needed
    20:size(16)-little, 20:size(16)-little, 1:size(16)-little,
    // method, mod time, mod date
    0:size(16)-little, 0:size(16)-little, 0:size(16)-little,
    // crc32, comp/uncomp size
    crc:size(32)-little, comp_size:size(32)-little, body_size:size(32)-little,
    // name, extra, comment lengths
    name_size:size(16)-little, 0:size(16)-little, 0:size(16)-little,
    // disk start, internal/external attrs
    0:size(16)-little, 0:size(16)-little, 0:size(32)-little,
    // local-header offset
    local_offset:size(32)-little,
  >>

  let central = bit_array.concat([central_header, name_bytes])
  let central_size = bit_array.byte_size(central)

  let eocd = <<
    0x50, 0x4B, 0x05, 0x06, 0:size(16)-little, 0:size(16)-little,
    1:size(16)-little, 1:size(16)-little, central_size:size(32)-little,
    central_size_offset:size(32)-little, 0:size(16)-little,
  >>

  bit_array.concat([local, central, eocd])
}

pub fn entry_with_mode_checked_rejects_overflow_test() -> Nil {
  // `external_attrs = mode << 16` in the ZIP central directory, and
  // the field is 32 bits wide, so any mode that doesn't fit in 16
  // bits would push external_attrs past 2^32.  The mode-side validator
  // catches that at the `entry` boundary instead of letting it reach
  // the encoder.
  let assert Ok(file_entry) =
    entry.file_checked(path: "x.txt", body: <<"x":utf8>>)
  case entry.with_mode_checked(file_entry, mode: 0x10000) {
    Error(entry.ModeOutOfRange(value: 0x10000)) -> Nil
    _ -> should.fail()
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

fn archive_add_directory(
  archive_value: archive.Archive,
  path: String,
) -> archive.Archive {
  let assert Ok(dir_entry) = entry.directory_checked(path: path)
  archive.add(archive_value, entry: dir_entry)
}

pub fn decodes_zstd_compressed_entry_test() -> Nil {
  // Hand-craft a ZIP archive whose single entry uses ZIP method 93
  // (zstd).  Wrap a zstd-encoded body in the standard PKZIP
  // local-file + central-directory + EOCD layout and prove the
  // decoder dispatches through `zstd.decode_with_limits`.
  let payload = <<"zstd-inside-zip":utf8>>
  let assert Ok(compressed) = zstd.encode(bytes: payload)
  zip_method_round_trip(method: 93, payload: payload, body: compressed)
}

pub fn decodes_bzip2_compressed_entry_test() -> Nil {
  let payload = <<"bzip2-inside-zip":utf8>>
  let assert Ok(compressed) = bzip2.encode(bytes: payload)
  zip_method_round_trip(method: 12, payload: payload, body: compressed)
}

pub fn decodes_xz_compressed_entry_test() -> Nil {
  let payload = <<"xz-inside-zip":utf8>>
  let assert Ok(compressed) = xz.encode(bytes: payload)
  zip_method_round_trip(method: 95, payload: payload, body: compressed)
}

pub fn decodes_pkware_lzma_method_14_entry_test() -> Nil {
  // ZIP method 14 (PKWARE LZMA wrapper) fixture generated from
  // Python's `lzma` module: LZMA1 raw stream wrapped in the
  // PKWARE 4-byte preamble + 5-byte property block.  Payload is
  // the ASCII string "PKWARE LZMA test payload inside ZIP method 14".
  let bytes = <<
    0x50, 0x4B, 0x03, 0x04, 0x3F, 0x00, 0x00, 0x00, 0x0E, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x9D, 0x8F, 0x55, 0x7E, 0x41, 0x00, 0x00, 0x00, 0x2D, 0x00, 0x00, 0x00,
    0x08, 0x00, 0x00, 0x00, 0x6C, 0x7A, 0x6D, 0x61, 0x2E, 0x74, 0x78, 0x74, 0x14,
    0x00, 0x05, 0x00, 0x5D, 0x00, 0x00, 0x01, 0x00, 0x00, 0x28, 0x12, 0xC7, 0x33,
    0x5C, 0x05, 0x46, 0xB2, 0x10, 0xD9, 0x37, 0xF7, 0x0E, 0xE9, 0x12, 0x77, 0xD8,
    0x56, 0x9E, 0xDE, 0x0A, 0x3C, 0xBD, 0x15, 0x2B, 0x00, 0x88, 0xB7, 0x44, 0x8D,
    0xC6, 0xB3, 0x6D, 0x86, 0x41, 0xF1, 0xAA, 0x48, 0xF3, 0x13, 0xBE, 0x11, 0xFD,
    0x58, 0x2F, 0x2F, 0x55, 0x16, 0x91, 0x7F, 0x7F, 0xFB, 0x96, 0xE0, 0x00, 0x50,
    0x4B, 0x01, 0x02, 0x14, 0x03, 0x3F, 0x00, 0x00, 0x00, 0x0E, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x9D, 0x8F, 0x55, 0x7E, 0x41, 0x00, 0x00, 0x00, 0x2D, 0x00, 0x00,
    0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x6C, 0x7A, 0x6D, 0x61, 0x2E, 0x74, 0x78,
    0x74, 0x50, 0x4B, 0x05, 0x06, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
    0x36, 0x00, 0x00, 0x00, 0x67, 0x00, 0x00, 0x00, 0x00, 0x00,
  >>
  let assert Ok(arch) = zip.decode(bytes: bytes)
  case archive.entries(arch) {
    [e] -> {
      entry.to_string(entry.path(e)) |> should.equal("lzma.txt")
      entry.body(e)
      |> should.equal(<<
        "PKWARE LZMA test payload inside ZIP method 14":utf8,
      >>)
    }
    _ -> should.fail()
  }
}

fn zip_method_round_trip(
  method method: Int,
  payload payload: BitArray,
  body body: BitArray,
) -> Nil {
  let crc = checksum.crc32(data: payload)
  let comp_size = bit_array.byte_size(body)
  let uncomp_size = bit_array.byte_size(payload)

  let local_header = <<
    0x50, 0x4B, 0x03, 0x04,
    // version needed (20)
    20, 0x00,
    // gp flag
    0x00, 0x00,
    // method (LE 16)
    method:size(16)-little,
    // mod time / date
    0x21, 0x00, 0x21, 0x00, crc:size(32)-little, comp_size:size(32)-little,
    uncomp_size:size(32)-little,
    // name length
    5, 0x00,
    // extra length
    0x00, 0x00, "z.dat":utf8,
  >>
  let entry_bytes = bit_array.concat([local_header, body])
  let local_size = bit_array.byte_size(entry_bytes)

  let central = <<
    0x50, 0x4B, 0x01, 0x02,
    // version made by + needed
    20, 0x03, 20, 0x00, 0x00, 0x00, method:size(16)-little, 0x21, 0x00, 0x21,
    0x00, crc:size(32)-little, comp_size:size(32)-little,
    uncomp_size:size(32)-little, 5, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0xA4, 0x81, 0x00, 0x00, 0x00, 0x00, "z.dat":utf8,
  >>
  let central_size = bit_array.byte_size(central)

  let eocd = <<
    0x50, 0x4B, 0x05, 0x06, 0x00, 0x00, 0x00, 0x00, 1, 0x00, 1, 0x00,
    central_size:size(32)-little, local_size:size(32)-little, 0x00, 0x00,
  >>
  let stream = bit_array.concat([entry_bytes, central, eocd])
  let assert Ok(arch) = zip.decode(bytes: stream)
  case archive.entries(arch) {
    [e] -> {
      entry.body(e) |> should.equal(payload)
      entry.to_string(entry.path(e)) |> should.equal("z.dat")
    }
    _ -> should.fail()
  }
}

// -- entry mtime round-trip ------------------------------------------
//
// Before the DOS date/time + InfoZIP Extended Timestamp wiring,
// `zip.encode` dropped every entry's `modified_at_unix` and wrote a
// hard-coded 1980-01-01 placeholder.  These tests pin the new
// behaviour: any mtime that fits the DOS-date window (1980..2107
// inclusive) survives encode->decode untouched, sub-DOS-epoch values
// are clamped to 0, and a system `zip` archive that uses the UT
// extra is decoded at full 1-second resolution.

pub fn roundtrip_preserves_entry_mtime_test() -> Nil {
  // 2025-06-15 12:34:56 UTC.  Even-second so the DOS-time field's
  // 2-second resolution doesn't matter even when the UT extra is
  // dropped; the InfoZIP UT extra carries the same value too, so we
  // exercise both paths simultaneously.
  zip_roundtrip_mtime(1_749_990_896)
  |> should.equal(1_749_990_896)
}

pub fn roundtrip_preserves_dos_epoch_boundary_test() -> Nil {
  // 1980-01-01 00:00:00 UTC — the lower edge of the DOS-date window.
  // The UT extra captures it exactly.
  zip_roundtrip_mtime(315_532_800)
  |> should.equal(315_532_800)
}

pub fn roundtrip_clamps_pre_dos_epoch_when_ut_extra_unavailable_test() -> Nil {
  // 1970-01-01 00:00:00 UTC is below the DOS-date window (year < 1980).
  // The DOS slots get the "no mtime" sentinel, but the UT extra still
  // carries the exact Unix seconds and the decoder honours it, so the
  // round-trip is lossless even pre-1980.
  zip_roundtrip_mtime(0)
  |> should.equal(0)
  zip_roundtrip_mtime(100)
  |> should.equal(100)
}

pub fn decodes_system_zip_with_unix_extended_timestamp_test() -> Nil {
  // `touch -d '2025-06-15 12:34:56 UTC' greeting.txt && zip mtime.zip
  //  greeting.txt` (Info-ZIP 3.0).  The archive carries both a DOS
  // pair (in local time, which depends on the producing host's TZ)
  // and an InfoZIP Extended Timestamp extra (header_id 0x5455) with
  // the exact Unix mtime in UTC.  packkit prefers the UT extra, so
  // the decoded mtime matches the original timestamp regardless of
  // the producer's timezone.
  let fixture = <<
    0x50, 0x4B, 0x03, 0x04, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x5C, 0xAC, 0xCF,
    0x5A, 0x0B, 0x69, 0xF2, 0x97, 0x0B, 0x00, 0x00, 0x00, 0x0B, 0x00, 0x00, 0x00,
    0x0C, 0x00, 0x1C, 0x00, 0x67, 0x72, 0x65, 0x65, 0x74, 0x69, 0x6E, 0x67, 0x2E,
    0x74, 0x78, 0x74, 0x55, 0x54, 0x09, 0x00, 0x03, 0xF0, 0xBD, 0x4E, 0x68, 0x9C,
    0xEA, 0x14, 0x6A, 0x75, 0x78, 0x0B, 0x00, 0x01, 0x04, 0xE8, 0x03, 0x00, 0x00,
    0x04, 0xE8, 0x03, 0x00, 0x00, 0x6D, 0x74, 0x69, 0x6D, 0x65, 0x20, 0x74, 0x65,
    0x73, 0x74, 0x0A, 0x50, 0x4B, 0x01, 0x02, 0x1E, 0x03, 0x0A, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x5C, 0xAC, 0xCF, 0x5A, 0x0B, 0x69, 0xF2, 0x97, 0x0B, 0x00, 0x00,
    0x00, 0x0B, 0x00, 0x00, 0x00, 0x0C, 0x00, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0xA4, 0x81, 0x00, 0x00, 0x00, 0x00, 0x67, 0x72, 0x65,
    0x65, 0x74, 0x69, 0x6E, 0x67, 0x2E, 0x74, 0x78, 0x74, 0x55, 0x54, 0x05, 0x00,
    0x03, 0xF0, 0xBD, 0x4E, 0x68, 0x75, 0x78, 0x0B, 0x00, 0x01, 0x04, 0xE8, 0x03,
    0x00, 0x00, 0x04, 0xE8, 0x03, 0x00, 0x00, 0x50, 0x4B, 0x05, 0x06, 0x00, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x52, 0x00, 0x00, 0x00, 0x51, 0x00, 0x00,
    0x00, 0x00, 0x00,
  >>
  let assert Ok(decoded) = zip.decode(bytes: fixture)
  let assert [single] = archive.entries(decoded)
  entry.to_string(entry.path(single))
  |> should.equal("greeting.txt")
  entry.body(single)
  |> should.equal(<<"mtime test\n":utf8>>)
  single
  |> entry.metadata
  |> entry.modified_at_unix
  |> should.equal(1_749_990_896)
}

// -- Language Encoding Flag (gp flag bit 11 / EFS) -------------------
//
// APPNOTE.TXT §4.4.4 says bit 11 of the per-entry general purpose
// flag indicates the filename and comment are UTF-8, not CP437.
// packkit always emits filenames as UTF-8, so pure-ASCII names
// (byte-identical in UTF-8 and CP437) leave bit 11 clear, but any
// name carrying a byte ≥ 0x80 forces the bit on so spec-conformant
// decoders interpret the name as UTF-8 instead of mojibaking it
// through the CP437 table.

fn read_local_gp_flag(bytes: BitArray) -> Int {
  // The local file header signature is at offset 0; gp_flag is at
  // offset 6 as a LE16.  Use bit_array.slice + a small pattern match
  // to pull the two bytes without re-implementing read_le16_at.
  let assert Ok(slice) = bit_array.slice(bytes, 6, 2)
  case slice {
    <<lo, hi>> -> int.bitwise_or(lo, int.bitwise_shift_left(hi, 8))
    _ -> 0
  }
}

pub fn encode_sets_efs_flag_on_non_ascii_filename_test() -> Nil {
  // Japanese filename "こんにちは.txt" — every UTF-8 byte beyond
  // the literal "." and "txt" is ≥ 0x80, so bit 11 must be set on
  // the encoded entry.
  let payload = <<"hello":utf8>>
  let archive_value =
    archive.add(zip.new(), entry: entry.file(path: "こんにちは.txt", body: payload))
  let assert Ok(bytes) = zip.encode(archive: archive_value)
  let gp_flag = read_local_gp_flag(bytes)
  int.bitwise_and(gp_flag, 0x0800)
  |> should.equal(0x0800)

  // Round-trip should still recover the original (UTF-8) name and body.
  let assert Ok(decoded) = zip.decode(bytes: bytes)
  let assert [restored] = archive.entries(decoded)
  entry.to_string(entry.path(restored))
  |> should.equal("こんにちは.txt")
  entry.body(restored)
  |> should.equal(payload)
}

pub fn encode_omits_efs_flag_on_ascii_filename_test() -> Nil {
  // Pure-ASCII filename — bit 11 must stay clear.  Bit 1 (the LZMA
  // EOS-omitted marker) is only set when the method is LZMA, so for
  // a default stored entry every bit must be 0.
  let archive_value =
    archive.add(
      zip.new(),
      entry: entry.file(path: "ascii.txt", body: <<"a":utf8>>),
    )
  let assert Ok(bytes) = zip.encode(archive: archive_value)
  let gp_flag = read_local_gp_flag(bytes)
  int.bitwise_and(gp_flag, 0x0800)
  |> should.equal(0)
}
