# Changelog

## Unreleased

- Scaffolded the repository as a cross-target Gleam package.
- Added an opaque-first public API skeleton for codecs, archives,
  recipes, safe entries, limits, and detection.
- Implemented the foundational compression and archive engines:
  Adler-32 / CRC-32 / CRC-32C / bzip2 CRC-32 checksums, tar (USTAR),
  cpio (newc), ar (BSD long-name), zip (stored and deflate),
  DEFLATE decode (all RFC 1951 block types) plus a fixed-Huffman
  LZ77 encoder, zlib, gzip, lz4 (frame), and snappy (raw + framed).
- Added the bzip2 family: pure-Gleam decoder (inverse BWT, MTF,
  grouped Huffman, RUNA/RUNB, RLE1) and encoder (naive forward BWT,
  length-limited Huffman) with round-trip tests.
- Added the Unix LZW `.Z` (compress) encoder and decoder, including
  the width-change / clear-table padding rules and the KwKwK
  exception in the decoder.
- Added the xz codec: stream header / block header / index / footer
  framing plus LZMA2 uncompressed and compressed chunks.  Built the
  underlying LZMA range coder (12-state machine, literal / match /
  repeat decoders, length and distance bit-trees) at
  `packkit/internal/lzma`.
- Added a 7z reader covering the common `7z a` single-file case
  (single folder, single coder, raw LZMA `03 01 01` or LZMA2 `21`).
- Added a Zstandard decoder covering frame envelope + raw + RLE
  blocks + FSE-compressed sequences (Raw / RLE literals, predefined
  FSE modes).  The FSE primitives live in `packkit/internal/fse`
  along with the predefined LL/ML/Offset distributions and the LL /
  ML base+extra-bits lookup tables.
- Added a Brotli decoder covering the empty stream and any
  `ISUNCOMPRESSED` metablock (RFC 7932 §9.2).
- Extended the Brotli decoder to parse compressed metablocks
  through the entire header pipeline: NBLTYPES, NPOSTFIX/NDIRECT,
  literal context modes, NTREES, and all three prefix-code
  descriptors in both simple form (§3.4) and complex form (§3.5,
  the 18-symbol code-length code with 16/17 run-length symbols).
  The command loop and the 122 KiB static dictionary are still
  pending; the decoder reports each missing stage with a
  fine-grained `CodecNotImplemented(feature: …)` error.
- Fixed the WBITS prefix decoder (RFC 7932 §9.1) for the
  `1 000 nnn` branch — previously returned `17 + extra` instead
  of `8 + extra` for `nnn ∈ {2..7}` and now rejects the
  large-window indicator with a typed error.
- Added GNU long-name (`L`) and long-link (`K`) decoding to the
  USTAR tar reader, plus permissive skipping of PAX extended-
  attribute headers (`x`, `g`).
- Wired the `packkit.compress` / `decompress` / `read` / `write` /
  `pack` / `unpack` facade and turned byte-signature detection into a
  real magic-number scan.
