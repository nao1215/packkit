# Changelog

## Unreleased

- Scaffolded the repository as a cross-target Gleam package.
- Added an opaque-first public API skeleton for codecs, archives,
  recipes, safe entries, limits, and detection.
- Implemented the foundational compression and archive engines:
  Adler-32 / CRC-32 checksums, tar (USTAR), cpio (newc), ar
  (BSD long-name), zip (stored), DEFLATE decode (all RFC 1951 block
  types) and stored-block encode, zlib, and gzip.
- Wired the `packkit.compress` / `decompress` / `read` / `write` /
  `pack` / `unpack` facade and turned byte-signature detection into a
  real magic-number scan.
