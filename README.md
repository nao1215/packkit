# packkit

`packkit` is a Gleam library for archive, compression, and container
workflows on the Erlang and JavaScript targets.

## Design stance

`packkit` treats these as different concepts:

- **codec**: bytes in, bytes out (`gzip`, `zlib`, `deflate`, `lz4`, ...)
- **archive**: entries in, bytes out (`tar`, `zip`, `cpio`, `7z`, ...)
- **recipe**: one archive plus zero or more outer codecs (`tar.gz`,
  `tar.lz4`, `cpio.zst`, ...)

`zip` and `7z` stay in the archive family. They are not modelled as
recipes just because they may compress their members internally.

## Status

Implemented codecs and archive families:

- **checksum**: Adler-32, CRC-32 (reflected), CRC-32C (Castagnoli),
  bzip2 CRC-32 (non-reflected)
- **tar**: USTAR encode/decode (regular files, directories, symlinks,
  hardlinks, prefix/name split)
- **cpio**: newc encode/decode
- **ar**: BSD long-name encode/decode
- **zip**: stored-method encode/decode with CRC-32 verification, plus
  per-entry deflate decode
- **7z**: single-folder LZMA / LZMA2 reader (covers the common
  `7z a` single-file case)
- **deflate**: full RFC 1951 decoder (stored, fixed, dynamic Huffman);
  LZ77 encoder (3-byte hash chain, 32 KiB window) with fixed-Huffman
  (`deflate.encode`) and dynamic-Huffman (`deflate.encode_dynamic`)
  block writers, plus a stored-only entry (`deflate.encode_stored_only`)
- **zlib**: RFC 1950 wrapper with Adler-32 trailer
- **gzip**: RFC 1952 wrapper with header metadata and CRC/ISIZE
  verification
- **lz4**: frame decoder + uncompressed-block encoder
- **snappy**: raw-block and framed codec
- **bzip2**: round-trip (BWT inverse + MTF + Huffman + RUNA/RUNB + RLE1
  for decode; naive forward BWT + length-limited Huffman for encode)
- **lzw**: Unix `.Z` (compress) encoder + decoder
- **xz**: stream header / block header / index / footer + LZMA2 with
  both uncompressed and LZMA-compressed chunks (via the pure-Gleam
  LZMA range coder in `packkit/internal/lzma`)
- **zstd**: frame envelope + raw + RLE + FSE-compressed blocks
  with Raw / RLE literals and predefined FSE modes; Huffman
  literals and non-predefined FSE modes still pending
- **brotli**: full RFC 7932 decoder (uncompressed + compressed
  metablocks, static dictionary, context maps, block switching).
  Encoder emits uncompressed metablocks only — the stream is a
  valid brotli stream that any conforming decoder accepts, but
  does no actual LZ77/Huffman compression yet.

The facade (`packkit.compress`, `packkit.decompress`, `packkit.read`,
`packkit.write`, `packkit.pack`, `packkit.unpack`) is wired to these
engines and honours the codec's optional level and preset-dictionary
settings; unsupported combinations are reported with the typed
`CodecOptionUnsupported` error rather than silently ignored.
Filename- and byte-signature-based detection are both available, and
the signatures are matched strictly (gzip requires CM=8, zlib
verifies the RFC 1950 check bits, bzip2 requires the block-size
digit, ...).

Still pending: zstd compressed-block Huffman literals and
non-predefined FSE modes, brotli LZ77/Huffman compression in the
encoder, and zstd / xz / 7z encoders that do real compression.

## Install

```sh
gleam add packkit
```

## Examples

### Build and inspect an archive

```gleam
import packkit/recipe
import packkit/tar

pub fn build_plan() {
  let archive =
    tar.new()
    |> tar.add_file("doc/readme.txt", <<"hello":utf8>>)
    |> tar.add_directory("assets")

  let pipeline = recipe.tar_gzip()

  #(archive, pipeline)
}
```

### Pack a tar.gz

```gleam
import packkit
import packkit/recipe
import packkit/tar

pub fn build_tar_gz() {
  let archive =
    tar.new()
    |> tar.add_file("hello.txt", <<"hello":utf8>>)
    |> tar.add_file("world.txt", <<"world":utf8>>)

  let assert Ok(bytes) =
    packkit.pack(archive_value: archive, using: recipe.tar_gzip())
  bytes
}
```

### Decompress gzip data

```gleam
import packkit/gzip

pub fn read_gzip(bytes: BitArray) {
  let assert Ok(decoded) = gzip.decode(bytes: bytes)
  decoded.payload
}
```

## Development

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the local workflow.
