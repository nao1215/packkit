# packkit

[![Package Version](https://img.shields.io/hexpm/v/packkit)](https://hex.pm/packages/packkit)
[![Downloads](https://img.shields.io/hexpm/dt/packkit)](https://hex.pm/packages/packkit)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/packkit/)
[![CI](https://github.com/nao1215/packkit/actions/workflows/ci.yml/badge.svg)](https://github.com/nao1215/packkit/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/nao1215/packkit)](LICENSE)

Archive, compression, and container workflows for Gleam — pure Gleam,
zero runtime dependencies, runs on both the Erlang and JavaScript
targets. Full API reference at <https://hexdocs.pm/packkit/>.

`packkit` keeps three concepts separate, so each is testable in
isolation and reusable in any combination:

- **codec** — bytes in, bytes out (`gzip`, `zlib`, `zstd`, `xz`,
  `bzip2`, `lz4`, `snappy`, `lzw`, `brotli`, `deflate`).
- **archive** — entries in, bytes out (`tar`, `zip`, `cpio`, `ar`,
  `7z`).
- **recipe** — one archive plus zero or more outer codecs
  (`tar.gz`, `tar.zst`, `cpio.xz`, …).

`zip` and `7z` stay in the archive family. They are not modelled as
recipes just because they may compress members internally — see
[ZIP per-entry methods](#zip-per-entry-methods) for that knob.

Every example below is checked by
[`test/packkit/readme_examples_test.gleam`](test/packkit/readme_examples_test.gleam),
so if it appears here it compiles and round-trips.

## Install

```sh
gleam add packkit
```

## Quick start: pack and unpack a tar.gz

The shortest end-to-end path. Build a logical archive, hand it to
`packkit.pack` with a recipe, get bytes back. `packkit.unpack` reverses
the recipe — gunzip, then tar-decode — and returns the same logical
archive.

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

For raw byte-to-byte work, skip the archive layer and call the codec
facade directly. The codec value carries its level and optional preset
dictionary — unsupported combinations surface as
`CodecOptionUnsupported`, never as a silent drop.

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

The same call shape works for every supported codec. Pick the one that
matches the input or the producer:

```gleam
import packkit
import packkit/codec

pub fn zstd_roundtrip(payload: BitArray) -> BitArray {
  let assert Ok(stream) = packkit.compress(bytes: payload, with: codec.zstd())
  let assert Ok(plain) = packkit.decompress(bytes: stream, with: codec.zstd())
  plain
}

pub fn bzip2_roundtrip(payload: BitArray) -> BitArray {
  let assert Ok(stream) = packkit.compress(bytes: payload, with: codec.bzip2())
  let assert Ok(plain) = packkit.decompress(bytes: stream, with: codec.bzip2())
  plain
}

pub fn brotli_roundtrip(payload: BitArray) -> BitArray {
  let assert Ok(stream) = packkit.compress(bytes: payload, with: codec.brotli())
  let assert Ok(plain) = packkit.decompress(bytes: stream, with: codec.brotli())
  plain
}
```

`codec.identity()` is a no-op codec — useful when a recipe needs to be
parameterised over "compress or not" without branching at the call site.

## Building archives

`tar`, `cpio`, `ar`, `zip`, and `7z` share one logical `Archive` value.
The format-specific module (`packkit/tar`, `packkit/zip`, …) exposes a
`new/0` constructor; from there, `archive.add_file` / `add_directory` /
`add_symlink` / `add_hardlink` work identically across formats.
Format-side limitations (e.g. `ar` only carries flat files) surface at
encode time as a typed `ArchiveError`.

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

`entry.with_mode` / `with_owner` / `with_modified_at` mutate an opaque
`Entry` value. The checked variants
(`with_mode_checked`, `with_owner_checked`, `with_modified_at_checked`)
return `Result(_, MetadataError)` instead of panicking when the value
is out of range; reach for them in code that touches user input.

### Path validation

`Entry` paths are validated up-front. Absolute paths, `..` traversal,
embedded NUL, Windows separators, empty / `.` segments all surface as
typed `EntryError` variants — there's no way to construct an
`Entry` value that would silently extract outside its archive root.

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

### CPIO, ar, 7z

The same `archive.add_*` helpers work for every format. Use
`packkit.write` to serialise.

```gleam
import packkit
import packkit/archive
import packkit/cpio
import packkit/ar
import packkit/seven_z

pub fn build_cpio() -> BitArray {
  let archive_value =
    cpio.new()
    |> archive.add_file(path: "lib/libfoo.so", body: <<"…":utf8>>)
    |> archive.add_file(path: "lib/libbar.so", body: <<"…":utf8>>)
  let assert Ok(bytes) =
    packkit.write(archive_value: archive_value, format: cpio.format())
  bytes
}

pub fn build_ar() -> BitArray {
  let archive_value =
    ar.new()
    |> archive.add_file(path: "main.o", body: <<"obj":utf8>>)
    |> archive.add_file(path: "debian-binary", body: <<"2.0\n":utf8>>)
  let assert Ok(bytes) =
    packkit.write(archive_value: archive_value, format: ar.format())
  bytes
}

pub fn build_seven_z() -> BitArray {
  let archive_value =
    seven_z.new()
    |> archive.add_file(path: "doc/spec.txt", body: <<"hello 7z":utf8>>)
    |> archive.add_file(path: "doc/notes.txt", body: <<"more":utf8>>)
  let assert Ok(bytes) =
    packkit.write(archive_value: archive_value, format: seven_z.format())
  bytes
}
```

## Recipe composition

A `Recipe` is one archive plus zero or more outer codecs in
outer-to-inner order. `packkit/recipe` ships convenience constructors
for the common combinations:

| Constructor              | Description |
|--------------------------|-------------|
| `recipe.tar()`           | uncompressed tar (same API surface as the compressed variants) |
| `recipe.zip()`           | ZIP archive (per-entry compression — see below) |
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

Need a recipe that isn't in the table? Compose one with `recipe.wrap`.
The wrapper adds an outer codec layer on top of an existing recipe.

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

`recipe.description` returns the canonical dotted name
(`"cpio-newc.lz4.zstd"` for the recipe above), which is handy for
test snapshots and logs.

## Detecting a format

Three entry points return an opaque `Detected` value, inspected through
`detect.codec` / `detect.archive` / `detect.recipe` / `detect.extension`.
Compound extensions (`.tar.gz`, `.cpio.zst`, …) take precedence over
their inner counterparts.

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

For incoming data of unknown origin (uploads, stdin) prefer
`detect.from_path_or_bytes` — it tries the filename first and falls
back to magic-byte sniffing on the supplied content.

```gleam
import gleam/option.{type Option}
import packkit/codec
import packkit/detect

/// Pick the right codec for a downloaded blob even when the URL has no
/// useful extension (`/dev/stdin`, `download.bin`, …).
pub fn pick_codec(path: String, leading_bytes: BitArray) -> Option(codec.Codec) {
  detect.from_path_or_bytes(path: path, bytes: leading_bytes)
  |> option.from_result
  |> option.then(detect.codec)
}
```

`packkit.detect_filename` / `detect_bytes` / `detect_path_or_bytes`
re-export the `packkit/detect` entrypoints from the top-level facade so
most CLI integrations only need to import `packkit`.

## Inspecting an archive

The decoded `Archive` is iterated through `archive.entries`; each
`Entry` is opaque and inspected through accessors. `archive.entry_by_path`
short-circuits the "fetch one named member" use case.

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

ZIP is an archive family, not a recipe — each entry can carry its own
compression method. `zip.encode_with_method` applies the chosen method
to every entry; mix-and-match per entry is not (yet) exposed. The
supported methods are `store`, `deflate`, `bzip2`, `zstd`, `xz`, and
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

pub fn write_zstd_zip() -> BitArray {
  let archive_value =
    zip.new()
    |> archive.add_file(path: "blob.bin", body: <<"…":utf8>>)
  let assert Ok(bytes) =
    zip.encode_with_method(archive: archive_value, method: zip.zstd())
  bytes
}

pub fn read_zip(bytes: BitArray) -> Int {
  let assert Ok(decoded) = packkit.unpack(bytes: bytes, using: recipe.zip())
  archive.entry_count(decoded)
}
```

`zip.decode_with_password` reads PKWARE traditional ("ZipCrypto") and
WinZip AES (AE-1 / AE-2) entries through the same logical-archive API
once the password is supplied — see the docs for the supported method
matrix.

## gzip header metadata round-trip

`packkit/gzip` exposes the full RFC 1952 header (member name, comment,
mtime, optional extra subfields). The top-level facade hides the
header, but for tooling that needs to read or set those fields, use the
gzip module directly.

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

`gzip.decode` returns a `Decoded` record carrying both the original
header and the decoded payload, so callers can replay metadata from one
gzip stream into another.

## Streaming chunks via packkit/stream

`packkit/stream` exposes opaque incremental decoder and encoder states.
`push` / `push_encoder` buffer one chunk at a time and enforce
`max_input_bytes` as the chunks arrive; `finish` / `finish_encoder`
runs the actual codec once.

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

Every codec gets a matching constructor —
`new_deflate_decoder`, `new_zlib_decoder`, `new_lz4_decoder`,
`new_snappy_decoder`, `new_bzip2_decoder`, `new_lzw_decoder`,
`new_xz_decoder`, `new_zstd_decoder`, `new_brotli_decoder` — plus the
encoder twins (`new_gzip_encoder`, …, `encode_chunks`).

## Resource limits

`packkit/limit` carries a budget that every decode entry point honours:
input size, output size, member count, name length, entry depth, and
maximum window bits. The facade variants (`compress`, `decompress`,
`pack`, `unpack`) ship `*_with_limits` twins that thread a custom
`Limits` value through the codec chain *and* the archive decoder.

```gleam
import packkit
import packkit/codec
import packkit/error
import packkit/limit

/// Reject any gzip stream whose ciphertext is larger than 4 bytes.
/// Useful only as an illustration — production budgets live in the
/// megabytes.
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

The default budget is conservative (64 MiB in, 256 MiB out, 10 000
entries) — explicit limits in shared / multi-tenant code paths are
strongly recommended.

## Checksums

`packkit/checksum` ships the same checksum families the codec engines
use internally, exposed as standalone helpers.

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

`adler32_continue` and `crc32_continue` let callers chain rolling
checksums across multiple chunks without re-hashing the prefix.
`sha256_init` / `sha256_update` / `sha256_finalize` expose the same
streaming shape for SHA-256.

## Error handling

Every public entry point returns `Result(_, e)` with a typed error.
`packkit/error.format_*_error` emits a single user-facing line for each
family so CLI integrations can surface them as-is.

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

The full error families are:

- `CodecError` — `CodecInvalidData`, `CodecLimitExceeded`,
  `CodecDictionaryRequired`, `CodecDictionaryMismatch`,
  `CodecOptionUnsupported`, `CodecNotImplemented`.
- `ArchiveError` — `ArchiveUnsupported`, `ArchiveInvalid`,
  `ArchiveEntryRejected`, `ArchiveLimitExceeded`, `ArchiveNotImplemented`,
  `ArchiveCodecFailed` (wraps a `CodecError` so a recipe-time codec
  failure preserves its structured cause), `ArchiveFormatMismatch`,
  `ArchiveFieldOverflow`, `ArchiveCommentUnsupported`.
- `RecipeError` — `RecipeArchiveAlreadySet`, `RecipeEmptyCodecChain`,
  `RecipeUnsupportedComposition`, `RecipeNotImplemented`.
- `DetectError` — `DetectUnknownFormat`, `DetectNotImplemented`.

## Supported formats

Implemented codecs:

- **gzip** (RFC 1952 — header metadata, multi-member streams,
  CRC/ISIZE verification)
- **zlib** (RFC 1950 — Adler-32 trailer, preset dictionaries)
- **deflate** (RFC 1951 — full decoder; stored + fixed/dynamic-Huffman
  LZ77 encoders)
- **lz4** (frame decoder + LZ77 encoder; legacy `lz4c`
  `0x184C2102` frames decode too)
- **snappy** (raw block + framed codec, LZ77 block compressor)
- **bzip2** (round-trip; multi-stream `.bz2` concatenation decodes)
- **lzw** (Unix `.Z` encoder + decoder)
- **xz** (stream header / block / index / footer + LZMA2 with both
  uncompressed and LZMA-compressed chunks, BCJ filter pre-processors,
  all four block-check types incl. SHA-256, multi-stream concatenation)
- **zstd** (frame envelope + raw / RLE / FSE-compressed blocks,
  Huffman-coded literals, treeless literals, predefined / RLE / FSE
  sequence modes, multi-frame stream decoding, real LZ77 sequences on
  the encode side)
- **brotli** (full RFC 7932 decoder; encoder picks the smallest of
  three candidates per payload, with a real LZ77 + complex-form
  Huffman LZ77 path)

Implemented archive families:

- **tar** — USTAR encode/decode plus GNU `LongName`/`LongLink` and PAX
  attribute (`x` / `g`) decoder
- **cpio** — newc encode/decode
- **ar** — BSD long-name encode/decode; the decoder also accepts the
  GNU long-name string table form (`//` + `/<offset>`), so `.a` /
  `.deb` archives produced by `binutils ar` round-trip end-to-end
- **zip** — stored + deflate + bzip2 + zstd + xz + PKWARE LZMA
  (method 14) encode/decode, Zip64 extensions, ZipCrypto + WinZip AES
  (AE-1 / AE-2) decryption, per-entry mtime / UID / GID, EFS UTF-8 names
- **7z** — single-folder reader for Copy / LZMA / LZMA2 / Deflate /
  BZip2 plus the BCJ + Delta filter family; encoder writes a
  single-folder archive with LZMA, Copy, Deflate, or BZip2 as the
  coder

Checksum primitives shared across codecs and exposed directly:

- Adler-32, CRC-32 (reflected), CRC-32C (Castagnoli), bzip2 CRC-32
  (non-reflected), CRC-64 (xz / ECMA reflected, returned as a
  `#(low_u32, high_u32)` pair for cross-target precision), SHA-1, and
  SHA-256 (FIPS 180-4)

For the full coverage matrix — including which encoder strategies are
currently exposed for each codec — see [CHANGELOG.md](CHANGELOG.md).

## Targets

Both the Erlang and JavaScript targets are exercised in CI on every
push. Pure-Gleam internals mean no NIF / native binary is needed.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for the local workflow.

```sh
just ci         # format-check + lint + typecheck + test
just test       # gleam test on the default target
```

## License

[MIT](LICENSE)
