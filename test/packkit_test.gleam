import gleam/bit_array
import gleam/list
import gleam/option
import gleam/result
import gleeunit
import gleeunit/should
import packkit
import packkit/archive
import packkit/codec
import packkit/fixture
import packkit/internal/entry
import packkit/limit

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn write_rejects_parent_traversal_test() -> Nil {
  fixture.new(archive.Tar)
  |> fixture.add_file(path: "../etc/passwd", body: <<"x":utf8>>)
  |> packkit.write
  |> should.equal(
    Error(archive.EntryRejected(path: "../etc/passwd", reason: "path traversal")),
  )
}

pub fn write_rejects_negative_metadata_test() -> Nil {
  let entry = fixture.file(path: "a", body: <<>>)
  let write = fn(entry) {
    packkit.write(archive.Archive(
      format: archive.Tar,
      entries: [entry],
      comment: option.None,
    ))
  }
  write(archive.Entry(..entry, mode: -1))
  |> should.equal(
    Error(archive.EntryRejected(path: "a", reason: "negative mode")),
  )
  write(archive.Entry(..entry, group_id: -1))
  |> should.equal(
    Error(archive.EntryRejected(path: "a", reason: "negative owner id")),
  )
  write(archive.Entry(..entry, modified_at: -1))
  |> should.equal(
    Error(archive.EntryRejected(path: "a", reason: "negative modification time")),
  )
}

pub fn facade_gzip_roundtrip_test() -> Nil {
  let payload = <<"hello from packkit":utf8>>
  let assert Ok(compressed) = packkit.compress(payload, with: codec.Gzip)
  let assert Ok(restored) = packkit.decompress(compressed, with: codec.Gzip)
  restored
  |> should.equal(payload)
}

pub fn facade_brotli_round_trip_test() -> Nil {
  // Brotli encode now emits uncompressed metablocks, so the facade
  // can round-trip end-to-end.  Regression for the period when the
  // encoder returned `CodecNotImplemented`.
  let payload = <<"facade-level brotli round trip":utf8>>
  let assert Ok(stream) = packkit.compress(payload, with: codec.Brotli)
  let assert Ok(restored) = packkit.decompress(stream, with: codec.Brotli)
  restored
  |> should.equal(payload)
}

pub fn facade_pack_unpack_tar_brotli_test() -> Nil {
  // tar.brotli now round-trips because brotli.encode is wired and the
  // facade no longer rejects the recipe at encode time.
  let archive_value =
    fixture.new(archive.Tar)
    |> fixture.add_file(path: "alpha.txt", body: <<"alpha":utf8>>)
    |> fixture.add_file(path: "beta.txt", body: <<"beta":utf8>>)
  let assert Ok(bytes) =
    packkit.pack(
      archive_value,
      using: packkit.Recipe(archive.Tar, [codec.Brotli]),
    )
  let assert Ok(decoded) =
    packkit.unpack(bytes, using: packkit.Recipe(archive.Tar, [codec.Brotli]))
  list.length(decoded.entries)
  |> should.equal(2)
}

pub fn facade_decompresses_brotli_stream_test() -> Nil {
  // Decoding a brotli stream through the facade must work — brotli.decode
  // is fully implemented, so packkit.decompress(..., with: codec.Brotli)
  // should succeed.  Regression for the bug where the facade had no
  // `"brotli" ->` dispatch and returned `CodecNotImplemented("decompress brotli")`.
  let assert Ok(stream) =
    bit_array.base16_decode("8F0480636C6F7564792064617903")
  let assert Ok(plain) = packkit.decompress(stream, with: codec.Brotli)
  plain
  |> should.equal(<<"cloudy day":utf8>>)
}

pub fn facade_pack_unpack_tar_gzip_test() -> Nil {
  let archive_value =
    fixture.new(archive.Tar)
    |> fixture.add_file(path: "hello.txt", body: <<"hello":utf8>>)
    |> fixture.add_file(path: "world.txt", body: <<"world":utf8>>)

  let assert Ok(bytes) =
    packkit.pack(
      archive_value,
      using: packkit.Recipe(archive.Tar, [codec.Gzip]),
    )
  let assert Ok(decoded) =
    packkit.unpack(bytes, using: packkit.Recipe(archive.Tar, [codec.Gzip]))

  list.length(decoded.entries)
  |> should.equal(2)
}

pub fn facade_pack_unpack_via_recipe_zip_test() -> Nil {
  // `packkit.Recipe(archive.Zip, [])` is the bare-archive convenience shortcut introduced
  // so callers can stay on the `packkit.pack` / `packkit.unpack` API
  // when targeting ZIP instead of switching to `packkit.write` /
  // `packkit.read`.  The same archive value must round-trip through
  // both paths byte-for-byte.
  let archive_value =
    fixture.new(archive.Zip)
    |> fixture.add(
      entry: fixture.file(path: "hello.txt", body: <<"hello":utf8>>),
    )
    |> fixture.add(
      entry: fixture.file(path: "world.txt", body: <<"world":utf8>>),
    )

  let assert Ok(bytes) =
    packkit.pack(archive_value, using: packkit.Recipe(archive.Zip, []))
  let assert Ok(decoded) =
    packkit.unpack(bytes, using: packkit.Recipe(archive.Zip, []))

  list.length(decoded.entries)
  |> should.equal(2)
}

pub fn facade_pack_unpack_via_recipe_tar_bare_test() -> Nil {
  // `packkit.Recipe(archive.Tar, [])` covers the uncompressed-tar case via the same
  // pack/unpack API.  Without the convenience shortcut callers had to
  // either write `recipe.archive_only(format: archive.Tar)` or fall
  // through to `packkit.write` / `packkit.read`.
  let archive_value =
    fixture.new(archive.Tar)
    |> fixture.add_file(path: "a.txt", body: <<"a":utf8>>)
    |> fixture.add_file(path: "b.txt", body: <<"b":utf8>>)
  let assert Ok(bytes) =
    packkit.pack(archive_value, using: packkit.Recipe(archive.Tar, []))
  let assert Ok(decoded) =
    packkit.unpack(bytes, using: packkit.Recipe(archive.Tar, []))
  list.length(decoded.entries)
  |> should.equal(2)
}

pub fn facade_bzip2_roundtrip_test() -> Nil {
  let payload = <<"facade-level bzip2 round trip":utf8>>
  let assert Ok(compressed) = packkit.compress(payload, with: codec.Bzip2)
  let assert Ok(restored) = packkit.decompress(compressed, with: codec.Bzip2)
  restored
  |> should.equal(payload)
}

pub fn facade_lzw_roundtrip_test() -> Nil {
  let payload = <<"facade-level LZW round trip":utf8>>
  let assert Ok(compressed) = packkit.compress(payload, with: codec.Lzw)
  let assert Ok(restored) = packkit.decompress(compressed, with: codec.Lzw)
  restored
  |> should.equal(payload)
}

pub fn facade_deflate_roundtrip_test() -> Nil {
  let payload = <<"deflate via facade — fixed Huffman LZ77":utf8>>
  let assert Ok(compressed) = packkit.compress(payload, with: codec.Deflate)
  let assert Ok(restored) = packkit.decompress(compressed, with: codec.Deflate)
  restored
  |> should.equal(payload)
}

// -- UX additions: recipe shortcuts, detect compound, limit unchecked,
//    gzip.decode_payload, ArchiveCodecFailed structured wrapping. -----

pub fn facade_pack_unpack_tar_bzip2_test() -> Nil {
  // End-to-end check for the previously-broken combination.
  let archive_value =
    fixture.new(archive.Tar)
    |> fixture.add_file(path: "a.txt", body: <<"alpha":utf8>>)
    |> fixture.add_file(path: "b.txt", body: <<"beta":utf8>>)
  let assert Ok(bytes) =
    packkit.pack(
      archive_value,
      using: packkit.Recipe(archive.Tar, [codec.Bzip2]),
    )
  let assert Ok(decoded) =
    packkit.unpack(bytes, using: packkit.Recipe(archive.Tar, [codec.Bzip2]))
  list.length(decoded.entries)
  |> should.equal(2)
}

pub fn unpack_failure_preserves_structured_codec_error_test() -> Nil {
  // When a codec step inside a recipe fails, the structured cause
  // must surface instead of a flattened string.
  packkit.unpack(
    <<"not gzip":utf8>>,
    using: packkit.Recipe(archive.Tar, [codec.Gzip]),
  )
  |> should.equal(
    Error(archive.CodecFailed(
      step: "decode",
      cause: codec.InvalidData(message: "gzip header truncated"),
    )),
  )
}

pub fn write_accepts_matching_format_test() -> Nil {
  let tar_archive =
    fixture.new(archive.Tar)
    |> fixture.add_file(path: "x.txt", body: <<"x":utf8>>)
  case packkit.write(tar_archive) {
    Ok(_) -> Nil
    _ -> should.fail()
  }
}

pub fn pack_rejects_recipe_format_mismatch_test() -> Nil {
  // The recipe declares the archive layer; if the supplied archive
  // value was constructed for a different format, `pack` must refuse
  // before touching the codec chain.
  let zip_archive_value =
    fixture.new(archive.Zip)
    |> fixture.add(entry: fixture.file(path: "x", body: <<"x":utf8>>))

  packkit.pack(
    zip_archive_value,
    using: packkit.Recipe(archive.Tar, [codec.Gzip]),
  )
  |> should.equal(
    Error(archive.FormatMismatch(archive: archive.Zip, requested: archive.Tar)),
  )
}

pub fn decompress_with_limits_propagates_input_limit_test() -> Nil {
  // The supplied Limits value must reach the underlying codec; if it
  // didn't, an oversized stream would still decode under the codec's
  // own default limits.  Use gzip because it has a cheap, deterministic
  // encoding for any payload.
  let payload = <<"limits propagation regression":utf8>>
  let assert Ok(stream) = packkit.compress(payload, with: codec.Gzip)
  let tight = limit.Limits(..limit.default(), max_input_bytes: 4)
  case packkit.decompress_with_limits(stream, with: codec.Gzip, limits: tight) {
    Error(codec.LimitExceeded(limit: "max_input_bytes", actual: _)) -> Nil
    _ -> should.fail()
  }
}

pub fn decompress_with_limits_identity_enforces_input_limit_test() -> Nil {
  // Even the identity codec must observe `max_input_bytes` when given
  // explicit limits, so the no-op path is consistent with every other
  // codec.
  let tight = limit.Limits(..limit.default(), max_input_bytes: 4)
  case
    packkit.decompress_with_limits(
      <<"longer than 4":utf8>>,
      with: codec.Identity,
      limits: tight,
    )
  {
    Error(codec.LimitExceeded(limit: "max_input_bytes", actual: _)) -> Nil
    _ -> should.fail()
  }
}

pub fn read_with_limits_propagates_to_archive_decoder_test() -> Nil {
  // `packkit.read_with_limits` must hand the Limits to the archive
  // family's `decode_with_limits` rather than re-defaulting them.
  let archive_value =
    fixture.new(archive.Tar)
    |> fixture.add_file(path: "a.txt", body: <<>>)
    |> fixture.add_file(path: "b.txt", body: <<>>)
    |> fixture.add_file(path: "c.txt", body: <<>>)
  let assert Ok(bytes) = packkit.write(archive_value)
  let tight = limit.Limits(..limit.default(), max_members: 2)
  case packkit.read_with_limits(bytes, format: archive.Tar, limits: tight) {
    Error(archive.LimitExceeded(limit: "max_members", actual: _)) -> Nil
    _ -> should.fail()
  }
}

pub fn unpack_with_limits_propagates_to_codec_chain_test() -> Nil {
  // `unpack_with_limits` must thread Limits through both the codec
  // chain *and* the archive decoder.  Hit the codec leg by setting a
  // tight max_input_bytes that's smaller than the packed gzip stream.
  let archive_value =
    fixture.new(archive.Tar)
    |> fixture.add_file(path: "a.txt", body: <<"a":utf8>>)
  let assert Ok(bytes) =
    packkit.pack(
      archive_value,
      using: packkit.Recipe(archive.Tar, [codec.Gzip]),
    )
  let tight = limit.Limits(..limit.default(), max_input_bytes: 4)
  case
    packkit.unpack_with_limits(
      bytes,
      using: packkit.Recipe(archive.Tar, [codec.Gzip]),
      limits: tight,
    )
  {
    Error(archive.CodecFailed(
      step: "decode",
      cause: codec.LimitExceeded(limit: "max_input_bytes", actual: _),
    )) -> Nil
    _ -> should.fail()
  }
}

pub fn archive_entry_by_path_returns_first_inserted_on_duplicate_test() -> Nil {
  // The lookup must match `entries(arc) |> list.find(...)` — that is,
  // the *first* entry inserted with the given path wins, not the
  // newest.  Pre-refactor the impl searched the internal reversed
  // list and returned the newest, breaking the contract the docstring
  // promised.
  let archive_value =
    fixture.new(archive.Tar)
    |> fixture.add_file(path: "dup.txt", body: <<"first":utf8>>)
    |> fixture.add_file(path: "dup.txt", body: <<"second":utf8>>)

  let assert Ok(found) = archive.entry_by_path(archive_value, path: "dup.txt")
  entry.body(found)
  |> should.equal(<<"first":utf8>>)

  // The README's recipe for the entry `tar -xf` leaves on disk (the
  // last one) searches the reversed entry list.
  let assert Ok(last) =
    archive_value.entries
    |> list.reverse
    |> list.find(fn(e) { e.path == "dup.txt" })
  entry.body(last)
  |> should.equal(<<"second":utf8>>)
}

pub fn archive_entry_by_path_matches_list_find_on_entries_test() -> Nil {
  // The function should be observationally equal to
  // `entries(arc) |> list.find(predicate)`.  Pin that as a law so the
  // implementation cannot drift back to searching the reversed
  // internal list.
  let archive_value =
    fixture.new(archive.Tar)
    |> fixture.add_file(path: "a", body: <<"1":utf8>>)
    |> fixture.add_file(path: "b", body: <<"2":utf8>>)
    |> fixture.add_file(path: "a", body: <<"3":utf8>>)

  let via_find =
    archive.entry_by_path(archive_value, path: "a")
    |> result.map(entry.body)

  let via_list_find =
    archive_value.entries
    |> list.find(fn(e) { e.path == "a" })
    |> result.map(entry.body)

  via_find
  |> should.equal(via_list_find)
}
