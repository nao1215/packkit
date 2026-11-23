//// The examples in README.md, kept here so they keep compiling and
//// returning what the README says.

import gleam/list
import gleam/option.{None}
import gleeunit/should
import packkit
import packkit/archive.{Archive, Entry, File}
import packkit/codec

fn round_trip() -> Result(BitArray, codec.CodecError) {
  let assert Ok(compressed) =
    packkit.compress(<<"hello":utf8>>, with: codec.Zstd)
  packkit.decompress(compressed, with: codec.Zstd)
}

pub fn round_trip_test() -> Nil {
  round_trip()
  |> should.equal(Ok(<<"hello":utf8>>))
}

fn backup() -> List(String) {
  let script =
    archive.new_entry(path: "bin/run", kind: File(<<"#!/bin/sh\n":utf8>>))
  let backup =
    Archive(
      format: archive.Tar,
      entries: [
        archive.new_entry(path: "notes.txt", kind: File(<<"hello":utf8>>)),
        Entry(..script, mode: 0o755),
      ],
      comment: None,
    )
  let recipe = packkit.Recipe(format: archive.Tar, codecs: [codec.Gzip])
  let assert Ok(bytes) = packkit.pack(backup, using: recipe)
  let assert Ok(restored) = packkit.unpack(bytes, using: recipe)
  list.map(restored.entries, fn(entry) { entry.path })
}

pub fn backup_test() -> Nil {
  backup()
  |> should.equal(["notes.txt", "bin/run"])
}

fn describe(path: String, bytes: BitArray) -> String {
  case packkit.detect(path:, bytes:) {
    Ok(packkit.Compressed(_)) -> "a compressed stream"
    Ok(packkit.Archived(_)) -> "an archive"
    Error(Nil) -> "unknown"
  }
}

pub fn describe_test() -> Nil {
  describe("backup.tar.zst", <<>>)
  |> should.equal("an archive")
}
