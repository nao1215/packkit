# Testing

`just ci` runs everything below except the nightly job and mutation testing. Tests run on the Erlang and JavaScript targets, on the Gleam floor (1.14.0, OTP 27, Node 22) and on the latest Gleam 1.x.

## Examples and unit tests

`test/packkit/<format>_test.gleam` checks each codec and archive format (tar, zip, 7z, ar, cpio, gzip, zstd, xz, bzip2, lz4, snappy, brotli, LZW) against hand-made and specification inputs, including malformed and truncated streams and resource limits. `test/packkit/readme_examples_test.gleam` runs the README examples.

## Generated properties

`test/packkit/property_test.gleam` uses metamon: every codec decodes what it encodes, the tar and zip recipes round-trip random entries, `entry_by_path` agrees with a linear search, and the cumulative output limit holds across multi-member streams.

## Differential testing

- Fixed corpora: `test/packkit/gzip_differential_test.gleam`, `bzip2_differential_test.gleam`, `xz_differential_test.gleam` and `lz4_differential_test.gleam` decode streams written by the system `gzip`, `bzip2`, `xz` and `lz4` tools and compare with the original bytes.
- Random inputs: `test/packkit_reference_differential_test.gleam` compares packkit with OTP's `zlib`, `erlang:crc32` / `adler32` and `crypto` on the Erlang target and with Node's `zlib` and `crypto` on JavaScript (FFI in `test/packkit_reference_ffi.erl` and `.mjs`). The reference must inflate what packkit's fixed, dynamic and stored DEFLATE, zlib and gzip encoders write, packkit must decode what the reference compresses, and CRC-32, Adler-32, SHA-256, SHA-1, HMAC-SHA1 and PBKDF2-HMAC-SHA1 must agree, as must the incremental checksum APIs with the one-shot ones. Inputs mix arbitrary bytes with runs, repeated phrases and a phrase repeated after up to 1.5 KiB of filler, so the match finder and both Huffman modes are reached. A boundary test also plants a match at the first and last distance of every RFC 1951 distance bucket up to 32 KiB and matches of every length from 3 to 258.

## Nightly runs

`.github/workflows/nightly-property.yml` runs the whole suite ten times with `METAMON_RUNS_MULTIPLIER=10`, each pass with a new seed. A failure report prints its seed, so the case can be replayed with `metamon.with_seed` and kept as a regression test.

## Mutation testing

There is no mutation testing tool for Gleam, so `gleam_mutate.py` (from the mutation-testing lab in nao1215/debimate, with integer comparison and arithmetic operators added) is run by hand on a copy of the project. It rewrites one operator or boolean result at a time (`==`/`!=`, `<`/`<=`, `>`/`>=`, `+`/`-`, `&&`/`||`, `-> True`/`-> False`, a dropped `!`) and runs `gleam test` on the Erlang target. The score is killed / (killed + lived).

packkit has about 3000 mutants and the suite takes about 40 seconds, so the run is limited to the modules the reference differential test covers (`deflate`, `zlib`, `gzip`, `checksum`, 410 mutants) and to the tests that exercise them (`checksum_test`, `deflate_*`, `gzip_*`, `zlib_*`, `property_test`, `stream_test` and `packkit_reference_differential_test`).

| Date | Files | Killed | Lived | Score |
|---|---|---:|---:|---:|
| 2026-11-19 | `deflate`, `zlib`, `gzip`, `checksum`, before the reference differential test | 238 | 172 | 58.0% |
| 2026-11-19 | the same, with the random-input differential tests | 253 | 157 | 61.7% |
| 2026-11-19 | the same, plus the distance and length code boundaries | 286 | 124 | 69.8% |

The random inputs repeat phrases at only a few distances, so the encoder's distance-code table kept 34 survivors until `deflate_handles_every_distance_and_length_code_boundary_test` planted a match at the first and last distance of every bucket. The remaining survivors, grouped:

- `deflate` (99): the LZ77 match finder (`collect_lz77_tokens`, `emit_lz77`, `insert_hashes_in_range`), where a weaker search still emits a valid, only larger, stream; redundant lower-bound guards in the code tables that earlier arms already exclude; and decoder paths for malformed dynamic headers.
- `gzip` (18): validation of header extra subfields and modification times at their limits, and multi-member limits.
- `checksum` (4) and `zlib` (3): Adler-32's 5552-byte batching, which only matters for longer inputs, and limit checks at exactly the limit.
