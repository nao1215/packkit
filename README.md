# packkit

[![CI](https://github.com/nao1215/packkit/actions/workflows/ci.yml/badge.svg)](https://github.com/nao1215/packkit/actions/workflows/ci.yml)
[![Gitleaks](https://github.com/nao1215/packkit/actions/workflows/gitleaks.yml/badge.svg)](https://github.com/nao1215/packkit/actions/workflows/gitleaks.yml)
[![Trivy](https://github.com/nao1215/packkit/actions/workflows/trivy.yml/badge.svg)](https://github.com/nao1215/packkit/actions/workflows/trivy.yml)
[![OSV-Scanner](https://github.com/nao1215/packkit/actions/workflows/osv-scan.yml/badge.svg)](https://github.com/nao1215/packkit/actions/workflows/osv-scan.yml)
[![Hex](https://img.shields.io/hexpm/v/packkit)](https://hex.pm/packages/packkit)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/packkit/)
[![Hex Downloads](https://img.shields.io/hexpm/dt/packkit)](https://hex.pm/packages/packkit)
[![License](https://img.shields.io/github/license/nao1215/packkit)](./LICENSE)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/nao1215/packkit/badge)](https://scorecard.dev/viewer/?uri=github.com/nao1215/packkit)

Archive, compression, and container formats in pure Gleam, with no
runtime dependencies and no NIFs. CI runs it on Erlang and JavaScript.
The full API is on [HexDocs](https://hexdocs.pm/packkit/).

packkit keeps three things apart:

- A codec turns bytes into bytes: `gzip`, `zlib`, `zstd`, `xz`,
  `bzip2`, `lz4`, `snappy`, `lzw`, `brotli`, `deflate`.
- An archive turns entries into bytes: `tar`, `zip`, `cpio`, `ar`,
  `7z`.
- A recipe is one archive plus zero or more outer codecs: `tar.gz`,
  `tar.zst`, `cpio.xz`, and so on.

`zip` and `7z` count as archives even though they compress members
themselves; see [ZIP per-entry methods](#zip-per-entry-methods).

[`test/packkit/readme_examples_test.gleam`](test/packkit/readme_examples_test.gleam)
has a test for every example below.

## Install

```sh
gleam add packkit
```

## Quick start: pack and unpack a tar.gz

`packkit.pack` writes an archive through a recipe, and `packkit.unpack`
reverses it (gunzip, then tar decode).

```gleam
import packkit
import packkit/archive
import packkit/recipe
import packkit/tar

pub fn build_and_read_tar_gz() -> Int {
  let archive_value =
    tar.new()
    |> tar.add_file(path: "hello.txt", body: <<"hello":utf8>>)
    |> tar.add_file(path: "world.txt", body: <<"world":utf8>>)

  let assert Ok(bytes) =
    packkit.pack(archive_value: archive_value, using: recipe.tar_gzip())

  let assert Ok(decoded) =
    packkit.unpack(bytes: bytes, using: recipe.tar_gzip())

  archive.entry_count(decoded)
  // -> 2
}
```

## Compressing and decompressing a single byte stream

For plain byte streams, call the codec facade. A codec value carries its
level and optional preset dictionary, and an unsupported combination
returns `CodecOptionUnsupported`.

```gleam
import packkit
import packkit/codec

pub fn gzip_roundtrip(payload: BitArray) -> BitArray {
  let assert Ok(compressed) =
    packkit.compress(bytes: payload, with: codec.gzip())
  let assert Ok(restored) =
    packkit.decompress(bytes: compressed, with: codec.gzip())
  restored
}
```

Every codec uses the same call; swap `codec.gzip()` for `codec.zstd()`,
`codec.bzip2()`, `codec.brotli()` and so on. `codec.identity()` does
nothing, which lets a recipe take "compress or not" as a parameter.

## Building archives

`tar`, `cpio`, `ar`, `zip`, and `7z` share one `Archive` value. Start
from the format module's `new/0` (`tar.new()`, `cpio.new()`,
`seven_z.new()`, ...), add entries with `archive.add_file` /
`add_directory` / `add_symlink` / `add_hardlink`, and serialise with
`packkit.write` and the module's `format()`. What a format
cannot hold (for example, `ar` has only flat files) is reported at
encode time as an `ArchiveError`.

### Tar with directories, symlinks, and metadata

```gleam
import packkit
import packkit/archive
import packkit/entry
import packkit/tar

pub fn build_tar_with_metadata() -> BitArray {
  let archive_value =
    tar.new()
    |> tar.add_directory(path: "etc")
    |> tar.add_file(path: "etc/motd", body: <<"welcome":utf8>>)
    |> tar.add_symlink(path: "etc/banner", target: "motd")
    |> archive.add(
      entry: entry.file(path: "bin/run", body: <<"#!/bin/sh\n":utf8>>)
        |> entry.with_mode(mode: 0o755)
        |> entry.with_owner(user_id: 1000, group_id: 1000)
        |> entry.with_modified_at(unix_seconds: 1_700_000_000),
    )

  let assert Ok(bytes) =
    packkit.write(archive_value: archive_value, format: tar.format())
  bytes
}
```

`entry.with_mode` / `with_owner` / `with_modified_at` panic on an
out-of-range value. For user input use `with_mode_checked`,
`with_owner_checked` and `with_modified_at_checked`, which return
`Result(_, MetadataError)`.

### Path validation

Absolute paths, `..`, NUL, Windows separators and empty or `.` segments
are rejected with an `EntryError` when the entry is built, so no `Entry`
can point outside the archive root.

```gleam
import packkit/entry
import packkit/tar

pub fn rejects_traversal() -> Result(_, entry.EntryError) {
  tar.add_file_checked(
    archive: tar.new(),
    path: "../etc/passwd",
    body: <<"x":utf8>>,
  )
  // -> Error(entry.PathTraversal("../etc/passwd"))
}
```

## Recipe composition

A `Recipe` lists its outer codecs from outside in. `packkit/recipe` has
constructors for the common ones:

| Constructor              | Description |
|--------------------------|-------------|
| `recipe.tar()`           | uncompressed tar (same API surface as the compressed variants) |
| `recipe.zip()`           | ZIP archive (per-entry compression, see below) |
| `recipe.seven_z()`       | 7z archive |
| `recipe.cpio()`          | uncompressed cpio (newc) |
| `recipe.ar()`            | BSD ar |
| `recipe.tar_gzip()`      | `tar.gz` |
| `recipe.tar_zstd()`      | `tar.zst` |
| `recipe.tar_xz()`        | `tar.xz` |
| `recipe.tar_bzip2()`     | `tar.bz2` |
| `recipe.tar_lz4()`       | `tar.lz4` |
| `recipe.tar_snappy()`    | `tar.snappy` |
| `recipe.tar_lzw()`       | `tar.Z` |
| `recipe.tar_zlib()`      | `tar.zlib` |
| `recipe.tar_brotli()`    | `tar.br` |
| `recipe.cpio_gzip()` / `cpio_bzip2()` / `cpio_xz()` / `cpio_zstd()` | matching cpio variants |

`recipe.wrap` adds another outer codec to an existing recipe:

```gleam
import packkit/archive
import packkit/codec
import packkit/recipe

pub fn cpio_lz4_then_zstd() -> recipe.Recipe {
  // Inner-to-outer order: cpio → lz4 → zstd
  recipe.archive_with(format: archive.cpio_newc(), wrapped_by: codec.lz4())
  |> recipe.wrap(with: codec.zstd())
}
```

`recipe.description` gives the dotted name, `"cpio-newc.lz4.zstd"` for
the recipe above.

## Detecting a format

`packkit.detect_filename`, `detect_bytes` and `detect_path_or_bytes`
(re-exports of `packkit/detect`) return a `Detected` value; read it with
`detect.codec`, `detect.archive`, `detect.recipe` or `detect.extension`.
Compound extensions such as `.tar.gz` win over the inner one.

```gleam
import gleam/option.{type Option}
import packkit
import packkit/detect
import packkit/recipe

pub fn recipe_for_filename(path: String) -> Option(recipe.Recipe) {
  let assert Ok(info) = packkit.detect_filename(path)
  detect.recipe(info)
}
// recipe_for_filename("backup-2026-05-22.tar.gz")
//   -> Some(recipe.tar_gzip())
// recipe_for_filename("logs.tar.zst")
//   -> Some(recipe.tar_zstd())
```

For uploads or stdin, `detect.from_path_or_bytes` tries the filename and
then the magic bytes:

```gleam
import gleam/option.{type Option}
import packkit/codec
import packkit/detect

pub fn pick_codec(path: String, leading_bytes: BitArray) -> Option(codec.Codec) {
  detect.from_path_or_bytes(path: path, bytes: leading_bytes)
  |> option.from_result
  |> option.then(detect.codec)
}
```

## Inspecting an archive

`archive.entries` lists the decoded entries and `archive.entry_by_path`
fetches one.

```gleam
import gleam/list
import gleam/option.{None, Some}
import packkit
import packkit/archive
import packkit/entry
import packkit/recipe

pub fn extract_one_file(bytes: BitArray) -> Result(BitArray, Nil) {
  let assert Ok(decoded) = packkit.unpack(bytes: bytes, using: recipe.tar_gzip())
  case archive.entry_by_path(decoded, path: "hello.txt") {
    Ok(found) -> Ok(entry.body(found))
    Error(_) -> Error(Nil)
  }
}

pub fn list_files(bytes: BitArray) -> List(String) {
  let assert Ok(decoded) = packkit.unpack(bytes: bytes, using: recipe.tar_gzip())
  archive.entries(decoded)
  |> list.filter(entry.is_file)
  |> list.map(fn(e) { entry.to_string(entry.path(e)) })
}
```

A tar archive can hold two entries with the same path. `archive.entry_by_path`
returns the first of them, while `tar -xf` leaves the last one on disk. To get
the extracted-file view, search the reversed list:
`archive.entries(decoded) |> list.reverse |> list.find(fn(e) { entry.to_string(entry.path(e)) == path })`.

## ZIP per-entry methods

Each ZIP entry has its own compression method. `zip.encode_with_method`
applies one method to every entry; choosing per entry is not exposed
yet. The methods are `store`, `deflate`, `bzip2`, `zstd`, `xz`, and
`lzma` (PKWARE method 14).

```gleam
import packkit
import packkit/archive
import packkit/level
import packkit/recipe
import packkit/zip

pub fn write_deflated_zip() -> BitArray {
  let archive_value =
    zip.new()
    |> archive.add_file(path: "report.csv", body: <<"a,b,c\n1,2,3\n":utf8>>)
    |> archive.add_file(path: "notes.txt", body: <<"keep me":utf8>>)
  let assert Ok(bytes) =
    zip.encode_with_method(
      archive: archive_value,
      method: zip.deflate(level: level.default()),
    )
  bytes
}

pub fn read_zip(bytes: BitArray) -> Int {
  let assert Ok(decoded) = packkit.unpack(bytes: bytes, using: recipe.zip())
  archive.entry_count(decoded)
}
```

`zip.decode_with_password` reads PKWARE traditional ("ZipCrypto") and
WinZip AES (AE-1 / AE-2) entries; HexDocs lists the supported methods.

## gzip header metadata round-trip

The facade hides the gzip header. `packkit/gzip` reads and writes all of
RFC 1952's fields: member name, comment, mtime and extra subfields.

```gleam
import gleam/option.{Some}
import packkit/gzip

pub fn gzip_with_header_metadata(payload: BitArray) -> #(BitArray, Result(gzip.Decoded, _)) {
  let header =
    gzip.default_header()
    |> gzip.with_name(name: "report.csv")
    |> gzip.with_comment(comment: "generated by packkit")
    |> gzip.with_modified_at(unix_seconds: 1_700_000_000)

  let assert Ok(bytes) =
    gzip.encode_with_header(bytes: payload, header: header)
  #(bytes, gzip.decode(bytes: bytes))
}
```

`gzip.decode` returns the header together with the payload, so you can
copy metadata from one stream to another.

## Streaming chunks via packkit/stream

`push` / `push_encoder` buffer one chunk at a time and check
`max_input_bytes` as chunks arrive; `finish` / `finish_encoder` runs the
codec once.

```gleam
import packkit
import packkit/codec
import packkit/stream

pub fn streamed_gzip_roundtrip(payload: BitArray) -> BitArray {
  let assert Ok(stream_bytes) =
    packkit.compress(bytes: payload, with: codec.gzip())

  // Split the compressed stream into two arbitrary chunks; the decoder
  // doesn't care how the producer carved them up.
  let chunks = [stream_bytes, <<>>]

  let assert Ok(plain) =
    stream.decode_chunks(decoder: stream.new_gzip_decoder(), chunks: chunks)
  plain
}
```

Every codec has a constructor (`new_deflate_decoder`, `new_zlib_decoder`,
`new_lz4_decoder`, `new_snappy_decoder`, `new_bzip2_decoder`,
`new_lzw_decoder`, `new_xz_decoder`, `new_zstd_decoder`,
`new_brotli_decoder`) and an encoder counterpart (`new_gzip_encoder`,
..., `encode_chunks`).

## Resource limits

Every decoder respects a `packkit/limit` budget: input size, output
size, member count, name length, entry depth and window bits.
`compress`, `decompress`, `pack` and `unpack` each have a
`*_with_limits` version that applies a custom `Limits` to both the codec
chain and the archive decoder. The default is 64 MiB in, 256 MiB out
and 10 000 entries; set explicit limits in shared or multi-tenant code.

```gleam
import packkit
import packkit/codec
import packkit/error
import packkit/limit

/// Reject any gzip stream larger than 4 bytes (a real budget would be
/// megabytes).
pub fn refuse_oversized_gzip(stream: BitArray) -> Bool {
  let tight = limit.default() |> limit.with_max_input_bytes(bytes: 4)
  case
    packkit.decompress_with_limits(
      bytes: stream,
      with: codec.gzip(),
      limits: tight,
    )
  {
    Error(error.CodecLimitExceeded(limit: "max_input_bytes", actual: _)) -> True
    _ -> False
  }
}
```

## Checksums

`packkit/checksum` exposes the checksums the codecs use.

```gleam
import packkit/checksum

pub fn checksums() -> #(Int, Int, BitArray) {
  let payload = <<"packkit":utf8>>
  #(
    checksum.adler32(data: payload),
    checksum.crc32(data: payload),
    checksum.sha256(data: payload),
  )
}
```

`adler32_continue` and `crc32_continue` carry a checksum across chunks,
and `sha256_init` / `sha256_update` / `sha256_finalize` do the same for
SHA-256.

## Error handling

Every public function returns a `Result` with a typed error, and
`packkit/error.format_*_error` turns each error into one line for users.

```gleam
import packkit
import packkit/archive
import packkit/error
import packkit/recipe
import packkit/tar
import packkit/zip
import packkit/entry

pub fn refuses_format_mismatch() -> String {
  // An `Archive` is bound to one format at construction time; asking
  // `pack` to write it as a different format is rejected up-front.
  let zip_archive_value =
    zip.new()
    |> archive.add(entry: entry.file(path: "x", body: <<"x":utf8>>))

  case packkit.pack(archive_value: zip_archive_value, using: recipe.tar_gzip()) {
    Error(err) -> error.format_archive_error(err)
    Ok(_) -> "ok"
  }
  // -> "archive: format mismatch (archive was built as \"zip\" but \"tar\" was requested)"
}
```

The error families:

- `CodecError`: `CodecInvalidData`, `CodecLimitExceeded`,
  `CodecDictionaryRequired`, `CodecDictionaryMismatch`,
  `CodecOptionUnsupported`, `CodecNotImplemented`.
- `ArchiveError`: `ArchiveUnsupported`, `ArchiveInvalid`,
  `ArchiveEntryRejected`, `ArchiveLimitExceeded`, `ArchiveNotImplemented`,
  `ArchiveCodecFailed` (wraps a `CodecError` so a recipe-time codec
  failure preserves its structured cause), `ArchiveFormatMismatch`,
  `ArchiveFieldOverflow`, `ArchiveCommentUnsupported`.
- `RecipeError`: `RecipeArchiveAlreadySet`, `RecipeEmptyCodecChain`,
  `RecipeUnsupportedComposition`, `RecipeNotImplemented`.
- `DetectError`: `DetectUnknownFormat`, `DetectNotImplemented`.

## Supported formats

Codecs:

- gzip (RFC 1952: header metadata, multi-member streams,
  CRC/ISIZE verification)
- zlib (RFC 1950: Adler-32 trailer, preset dictionaries)
- deflate (RFC 1951: full decoder; stored + fixed/dynamic-Huffman
  LZ77 encoders)
- lz4 (frame decoder + LZ77 encoder; legacy `lz4c`
  `0x184C2102` frames decode too)
- snappy (raw block + framed codec, LZ77 block compressor)
- bzip2 (round-trip; multi-stream `.bz2` concatenation decodes)
- lzw (Unix `.Z` encoder + decoder)
- xz (stream header / block / index / footer + LZMA2 with both
  uncompressed and LZMA-compressed chunks, BCJ filter pre-processors,
  all four block-check types incl. SHA-256, multi-stream concatenation)
- zstd (frame envelope + raw / RLE / FSE-compressed blocks,
  Huffman-coded literals, treeless literals, predefined / RLE / FSE
  sequence modes, multi-frame stream decoding, real LZ77 sequences on
  the encode side)
- brotli (full RFC 7932 decoder; encoder picks the smallest of
  three candidates per payload, with a real LZ77 + complex-form
  Huffman LZ77 path)

Archives:

- tar: USTAR encode/decode plus GNU `LongName`/`LongLink` and PAX
  attribute (`x` / `g`) decoder
- cpio: newc encode/decode
- ar: BSD long-name encode/decode; the decoder also accepts the
  GNU long-name string table form (`//` + `/<offset>`), so `.a` /
  `.deb` archives produced by `binutils ar` round-trip end-to-end
- zip: stored + deflate + bzip2 + zstd + xz + PKWARE LZMA
  (method 14) encode/decode, Zip64 extensions, ZipCrypto + WinZip AES
  (AE-1 / AE-2) decryption, per-entry mtime / UID / GID, EFS UTF-8 names
- 7z: single-folder reader for Copy / LZMA / LZMA2 / Deflate /
  BZip2 plus the BCJ + Delta filter family; encoder writes a
  single-folder archive with LZMA, Copy, Deflate, or BZip2 as the
  coder

Checksums:

- Adler-32, CRC-32 (reflected), CRC-32C (Castagnoli), bzip2 CRC-32
  (non-reflected), CRC-64 (xz / ECMA reflected, returned as a
  `#(low_u32, high_u32)` pair for cross-target precision), SHA-1, and
  SHA-256 (FIPS 180-4)

[CHANGELOG.md](CHANGELOG.md) records which encoder strategies each codec
has.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for the local workflow.

```sh
just ci         # format-check + lint + typecheck + test
just test       # gleam test on the default target
```

## Testing

| Technique | Bug class caught here |
|---|---|
| Examples and unit tests | [Wrong output or errors for a codec or archive format](doc/testing.md#examples-and-unit-tests) |
| Generated properties | [Encode / decode and archive round trips that lose bytes or entries](doc/testing.md#generated-properties) |
| Differential testing | [Streams other implementations cannot read; wrong checksums and hashes](doc/testing.md#differential-testing) |
| Nightly runs | [Rare inputs the normal run count misses](doc/testing.md#nightly-runs) |
| Mutation testing | [Assertions that miss a changed operator or branch](doc/testing.md#mutation-testing) |

## Verifying releases

Each GitHub Release attaches the Hex package tarball (`packkit-<version>.tar`),
`checksums.txt`, a cosign signature bundle (`checksums.txt.sigstore.json`) and
build provenance (`packkit-<version>.intoto.jsonl`). Download the assets, then:

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

[MIT](LICENSE)
