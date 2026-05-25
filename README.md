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

- **checksum**: Adler-32, CRC-32 (reflected), CRC-32C
  (Castagnoli), bzip2 CRC-32 (non-reflected), CRC-64 (xz / ECMA
  reflected, returned as a `#(low_u32, high_u32)` pair for
  cross-target precision), and SHA-256 (FIPS 180-4); the latter
  two back the xz block-check field for `check_type = 4` and
  `check_type = 10` respectively
- **tar**: USTAR encode/decode (regular files, directories, symlinks,
  hardlinks, prefix/name split)
- **cpio**: newc encode/decode
- **ar**: BSD long-name encode/decode; decoder also accepts the
  GNU long-name string-table form (`//` member + `/<offset>`
  references) so `.a` / `.deb` archives produced by `binutils ar`
  round-trip end-to-end
- **zip**: stored + deflate encode/decode with CRC-32 verification,
  plus Zip64 extensions (EOCD locator/record + per-entry header_id
  0x0001 extra field) so archives with > 65535 entries, > 4 GiB
  central directories, or > 4 GiB entries / offsets round-trip
  through any conforming Zip64 reader.  Methods 12 (bzip2), 93
  (zstd), and 95 (xz) round-trip in both directions: the encoder
  exposes `zip.bzip2()` / `zip.zstd()` / `zip.xz()` `Method`
  constructors that dispatch to the matching packkit codec, and
  the decoder reads the same methods back.  Method 14 (PKWARE
  LZMA wrapper around a raw LZMA1 stream) round-trips in both
  directions: the encoder is exposed as `zip.lzma()` and emits a
  literal-only LZMA1 stream (`packkit/internal/lzma.encode_literal_only`)
  with general-purpose flag bit 1 set so the decoder uses the
  central-directory uncompressed size instead of looking for an
  in-stream EOS marker.  The decoder side reads the 4-byte SDK
  preamble + 5-byte property block and hands the range-coded
  payload to the internal LZMA decoder.  Entries protected by
  PKWARE traditional ("ZipCrypto") encryption decode via
  `zip.decode_with_password` (the strong-encryption gp flag bit
  is rejected explicitly rather than decoded as ZipCrypto)
- **7z**: single-folder LZMA / LZMA2 reader (covers the common
  `7z a` single-file case).  The encoder builds a single-folder,
  single-coder archive with a raw LZMA1 coder, emitting the
  `PackInfo` / `UnPackInfo` / optional `SubStreamsInfo` blocks
  plus the `FilesInfo` UTF-16 LE name table.  Multi-file archives
  round-trip; non-`File` entries are rejected because the encoder
  does not emit `EmptyStream` / `Attribute` blocks yet
- **deflate**: full RFC 1951 decoder (stored, fixed, dynamic Huffman);
  LZ77 encoder (3-byte hash chain, 32 KiB window) with fixed-Huffman
  (`deflate.encode`) and dynamic-Huffman (`deflate.encode_dynamic`)
  block writers, plus a stored-only entry (`deflate.encode_stored_only`)
- **zlib**: RFC 1950 wrapper with Adler-32 trailer
- **gzip**: RFC 1952 wrapper with header metadata and CRC/ISIZE
  verification, plus multi-member stream decoding (concatenated
  gzip files such as `cat a.gz b.gz`)
- **lz4**: frame decoder + LZ77 block encoder (greedy 4-byte hash-
  chain match-finder with uncompressed-block fallback).
  `lz4.encode_with_content_size` additionally stores the
  uncompressed content size in the frame descriptor so strict
  decoders (the reference `lz4` CLI, for instance) can pre-allocate
  the output buffer and verify the declared length.  The legacy
  frame format (`lz4 -l` / `lz4c` magic `0x184C2102`) is also
  recognised and decoded
- **snappy**: raw-block and framed codec with LZ77 block compressor
  (greedy 4-byte hash-chain match-finder, literal + copy-1 / copy-2
  / copy-4 sequence emission)
- **bzip2**: round-trip (BWT inverse + MTF + Huffman + RUNA/RUNB + RLE1
  for decode; naive forward BWT + length-limited Huffman for encode);
  multi-stream `.bz2` files (the `bzcat`-style concatenation of
  several streams) decode end-to-end
- **lzw**: Unix `.Z` (compress) encoder + decoder
- **xz**: stream header / block header / index / footer + LZMA2 with
  both uncompressed and LZMA-compressed chunks (via the pure-Gleam
  LZMA range coder in `packkit/internal/lzma`); multi-stream files
  with 4-byte-aligned stream padding decode end-to-end.  Multi-filter
  chains terminating in LZMA2 are honoured with delta + the full
  BCJ pre-processor family (x86, PowerPC, IA-64, ARM, ARM-Thumb,
  SPARC, ARM64, RISC-V) inverted in reverse chain order.  All four
  RFC-defined block-check types are honoured: None (`0`), CRC-32
  (`1`), CRC-64 (`4`), and SHA-256 (`10`); the latter three
  verify the digest against the decoded payload rather than just
  asserting field length.  The encoder splits the payload across
  32 KiB LZMA2 LZMA chunks (control byte `0xE0`) and runs each
  through the literal-only LZMA1 encoder so the output is a fully
  conforming `.xz` file
- **zstd**: frame envelope + raw + RLE + FSE-compressed blocks
  with Raw / RLE literals, **Huffman-compressed literals** (both
  direct-weight and FSE-weight tree descriptions; both 1-stream
  and 4-stream jump-table forms), **treeless literals** (the
  prior block's Huffman tree is threaded through the block loop
  and reused), predefined / RLE / FSE-compressed sequence modes,
  and multi-frame stream decoding (concatenated zstd frames such
  as `cat a.zst b.zst`)
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

Still pending: brotli LZ77/Huffman compression in the encoder,
and a zstd encoder that also does LZ77 sequence emission.
The zstd encoder now emits a Compressed_Block with Huffman-coded
literals on both the 1-stream form (≤ 1023-byte chunks) and the
4-stream form (≤ 16 KiB chunks with a 6-byte jump table), holding
~50 % compression ratio on English-like text across a wide range
of input sizes.  The tree description picks the direct-weight
form when the alphabet streams ≤ 127 weights and the FSE-
compressed form (header byte 0..127 + FSE body) otherwise, so
alphabets that use byte values above 127 are now Huffman-encoded
instead of falling back to Raw / RLE.  The xz / 7z / ZIP method
14 encoders share a real LZ77 LZMA1 encoder
(`packkit/internal/lzma.encode_with_lz77`, 3-byte hash chain
with a 32 KiB window plus LZMA rep-match and short-rep emission
when the match distance hits the `rep0..rep3` ring) which
delivers real compression on repetitive payloads — e.g. an 80
KiB repeating-string xz file shrinks to ~388 bytes (0.49 %
ratio), 9 KiB of repeated pangrams to 148 bytes (1.6 %).

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
