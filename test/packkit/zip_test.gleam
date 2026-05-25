import gleam/bit_array
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
