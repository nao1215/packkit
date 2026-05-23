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
- Added a partial Zstandard decoder: frame envelope, raw and RLE
  blocks, plus the predefined FSE distributions at
  `packkit/internal/fse` ready for the entropy-decode follow-up.
- Added a partial Brotli decoder that recognises any empty stream via
  RFC 7932 WBITS + ISLASTEMPTY parsing.
- Wired the `packkit.compress` / `decompress` / `read` / `write` /
  `pack` / `unpack` facade and turned byte-signature detection into a
  real magic-number scan.
