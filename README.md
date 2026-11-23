# packkit

[![CI](https://github.com/nao1215/packkit/actions/workflows/ci.yml/badge.svg)](https://github.com/nao1215/packkit/actions/workflows/ci.yml)
[![Gitleaks](https://github.com/nao1215/packkit/actions/workflows/gitleaks.yml/badge.svg)](https://github.com/nao1215/packkit/actions/workflows/gitleaks.yml)
[![Trivy](https://github.com/nao1215/packkit/actions/workflows/trivy.yml/badge.svg)](https://github.com/nao1215/packkit/actions/workflows/trivy.yml)
[![OSV-Scanner](https://github.com/nao1215/packkit/actions/workflows/osv-scan.yml/badge.svg)](https://github.com/nao1215/packkit/actions/workflows/osv-scan.yml)
[![Hex](https://img.shields.io/hexpm/v/packkit)](https://hex.pm/packages/packkit)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/packkit/)
[![Hex Downloads](https://img.shields.io/hexpm/dt/packkit)](https://hex.pm/packages/packkit)
[![License](https://img.shields.io/github/license/nao1215/packkit)](https://github.com/nao1215/packkit/blob/main/LICENSE)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/nao1215/packkit/badge)](https://scorecard.dev/viewer/?uri=github.com/nao1215/packkit)

Compression and archive formats for Gleam, written in Gleam and running on the Erlang and JavaScript targets. It reads and writes gzip, zlib, raw DEFLATE, Zstandard, xz, bzip2, Brotli, LZ4, Snappy and Unix `compress`, and tar, ZIP, 7z, cpio and ar archives, with no NIFs and no dependency besides `gleam_stdlib`.

```sh
gleam add packkit@0
```

## Usage

Compressing and decompressing bytes:

```gleam
import packkit
import packkit/codec

pub fn round_trip() -> Result(BitArray, codec.CodecError) {
  let assert Ok(compressed) = packkit.compress(<<"hello":utf8>>, with: codec.Zstd)
  packkit.decompress(compressed, with: codec.Zstd)
  // -> Ok(<<"hello":utf8>>)
}
```

Writing a `.tar.gz` and reading it back. `Archive` and `Entry` are plain records:

```gleam
import gleam/list
import gleam/option.{None}
import packkit
import packkit/archive.{Archive, Entry, File}
import packkit/codec

pub fn backup() -> List(String) {
  let script = archive.new_entry(path: "bin/run", kind: File(<<"#!/bin/sh\n":utf8>>))
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
  // -> ["notes.txt", "bin/run"]
}
```

Choosing the format from the file name, or from the first bytes when the name has no known extension:

```gleam
import packkit

pub fn describe(path: String, bytes: BitArray) -> String {
  case packkit.detect(path:, bytes:) {
    Ok(packkit.Compressed(_)) -> "a compressed stream"
    Ok(packkit.Archived(_)) -> "an archive"
    Error(Nil) -> "unknown"
  }
  // describe("backup.tar.zst", <<>>) -> "an archive"
}
```

`packkit/zip` and `packkit/seven_z` pick the compression method and read encrypted archives, and `packkit/gzip` reads and writes the gzip header. The API reference is on [HexDocs](https://hexdocs.pm/packkit/).

## Notes

- Everything happens in memory. Each decoder stops with `LimitExceeded` at 64 MB of input, 256 MB of output or 10,000 entries; pass your own `Limits` to `decompress_with_limits`, `read_with_limits` or `unpack_with_limits`.
- Reading and writing reject entry paths that are absolute or contain `..`. Symbolic link targets are kept as they are, so check them before creating links on disk.
- 7z encryption uses an empty salt and a zero IV, so the same password and contents always give the same bytes.

How the package is tested is described in [doc/testing.md](https://github.com/nao1215/packkit/blob/main/doc/testing.md).

## Verifying releases

Each GitHub Release attaches the Hex package tarball (`packkit-<version>.tar`), `checksums.txt`, a cosign signature bundle (`checksums.txt.sigstore.json`) and build provenance (`packkit-<version>.intoto.jsonl`). Download the assets, then:

```sh
gh attestation verify packkit-<version>.tar --repo nao1215/packkit

cosign verify-blob \
  --bundle checksums.txt.sigstore.json \
  --certificate-identity-regexp '^https://github\.com/nao1215/packkit/\.github/workflows/release\.yml@refs/tags/v' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  checksums.txt
sha256sum --check checksums.txt
```

## License

[MIT](https://github.com/nao1215/packkit/blob/main/LICENSE)
