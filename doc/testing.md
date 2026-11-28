# Testing

`just ci` runs everything below except the nightly job and mutation testing. Tests run on the Erlang and JavaScript targets, on the Gleam floor (1.14.0, OTP 27, Node 22) and on the latest Gleam 1.x.

## Examples and unit tests

`test/packkit/<format>_test.gleam` checks each codec and archive format (tar, zip, 7z, ar, cpio, gzip, zstd, xz, bzip2, lz4, snappy, brotli, LZW) against hand-made and specification inputs, including malformed and truncated streams and resource limits. `test/packkit/readme_examples_test.gleam` runs the README examples.

## Limits and malformed input

`test/packkit/limits_matrix_test.gleam` reads a valid archive with every reader, ZIP method and 7z method and encryption mode, and a valid stream with every codec, with one field of `Limits` set just below what the input needs, and expects `LimitExceeded` naming that field. `test/packkit/length_field_test.gleam` and `unsafe_path_read_test.gleam` feed hand-made headers with negative, oversized or inconsistent length fields and paths with `..`, and `checksum_verification_test.gleam` flips bytes covered by the LZ4 and Snappy checksums.

`test/packkit/mutation_fuzz_test.gleam` starts from valid streams and archives for every decoder, applies one to four random edits (flipped bytes, truncation, inserted bytes, 32-bit fields overwritten with values such as `0xFFFFFFFF`, deleted runs) and checks that the decoder returns a `Result` within the limits: no panic or hang, no output over `max_output_bytes`, no more entries than `max_members`, and only safe paths within the name and depth limits. It uses metamon, so it draws a new seed on every run and the nightly job runs it with ten times the cases.

## Generated properties

`test/packkit/property_test.gleam` uses metamon: every codec decodes what it encodes, the tar and zip recipes round-trip random entries, `entry_by_path` agrees with a linear search, and the cumulative output limit holds across multi-member streams.

## Differential testing

- Fixed corpora: `test/packkit/gzip_differential_test.gleam`, `bzip2_differential_test.gleam`, `xz_differential_test.gleam` and `lz4_differential_test.gleam` decode streams written by the system `gzip`, `bzip2`, `xz` and `lz4` tools and compare with the original bytes.
- Random inputs: `test/packkit_reference_differential_test.gleam` compares packkit with OTP's `zlib`, `erlang:crc32` / `adler32` and `crypto` on the Erlang target and with Node's `zlib` and `crypto` on JavaScript (FFI in `test/packkit_reference_ffi.erl` and `.mjs`). The reference must inflate what packkit's fixed and dynamic DEFLATE, zlib and gzip encoders write, packkit must decode what the reference compresses, and CRC-32, Adler-32, SHA-256, SHA-1, HMAC-SHA1 and PBKDF2-HMAC-SHA1 must agree, as must the incremental SHA-256 with the one-shot one. Inputs mix arbitrary bytes with runs, repeated phrases and a phrase repeated after up to 1.5 KiB of filler, so the match finder and both Huffman modes are reached. A boundary test also plants a match at the first and last distance of every RFC 1951 distance bucket up to 32 KiB and matches of every length from 3 to 258.

## Nightly runs

`.github/workflows/nightly-property.yml` runs the whole suite ten times with `METAMON_RUNS_MULTIPLIER=10`, each pass with a new seed. A failure report prints its seed, so the case can be replayed with `metamon.Config(..metamon.default_config(), seed: Some(seed))` and kept as a regression test.

## Coverage

`gleam run -m metamon/mutation -- coverage` runs the Erlang tests with every module under `src/` measured by Erlang's `cover` and writes `build/coverage/lcov.info` with the line numbers of the Gleam source. It needs Gleam 1.19 or later, newer than the 1.14 lane of CI. `.github/workflows/coverage.yml` runs it on pull requests and pushes to main and reports it with octocov; the badge comes from nao1215/octocovs-central-repo. `just coverage` runs it locally. On 2026-11-28 it reached 83.6% of lines (8229 of 9846).

## Mutation testing

`gleam run -m metamon/mutation -- run` changes one operator, `!` or boolean literal in a module under `src/` at a time and runs `gleam test --target erlang` on each change; `gleam run -m metamon/mutation -- gate` then fails on a survivor that `doc/mutation/baseline.json` does not list. `src/packkit/internal/brotli_dictionary.gleam`, a generated table, is left out. `.github/workflows/mutation.yml` mutates the modules a pull request or push changes and runs the gate; the weekly run mutates every module in 16 parts that take about 170 minutes each. `just mutation` and `just mutation-record` run the same steps locally.

The baseline comes from the first full run on CI (2026-11-28, run 46076770221). To record a new one, download the `mutation-results` artifact of a weekly run to `build/mutation/results.json` and run `just mutation-record`, which also rewrites the table below. A loaded machine can time out tests that pass on CI, so record the baseline from a CI run.

<!-- mutation:start -->
| Module | Killed | Lived | Timed out | Score |
|---|---:|---:|---:|---:|
| `packkit` | 17 | 4 | 0 | 81.0% |
| `packkit/archive` | 1 | 0 | 0 | 100.0% |
| `packkit/gzip` | 15 | 13 | 0 | 53.6% |
| `packkit/internal/aes` | 12 | 1 | 0 | 92.3% |
| `packkit/internal/ar` | 16 | 15 | 0 | 51.6% |
| `packkit/internal/bcj` | 65 | 95 | 0 | 40.6% |
| `packkit/internal/bcj2` | 14 | 13 | 0 | 51.9% |
| `packkit/internal/brotli` | 237 | 166 | 0 | 58.8% |
| `packkit/internal/brotli_context` | 3 | 0 | 0 | 100.0% |
| `packkit/internal/brotli_transform` | 1 | 11 | 0 | 8.3% |
| `packkit/internal/bytes` | 12 | 7 | 0 | 63.2% |
| `packkit/internal/bzip2` | 150 | 55 | 1 | 73.3% |
| `packkit/internal/checksum` | 56 | 7 | 0 | 88.9% |
| `packkit/internal/cpio` | 37 | 11 | 0 | 77.1% |
| `packkit/internal/deflate` | 282 | 78 | 0 | 78.3% |
| `packkit/internal/entry` | 8 | 3 | 0 | 72.7% |
| `packkit/internal/fse` | 52 | 12 | 0 | 81.3% |
| `packkit/internal/huf` | 63 | 22 | 0 | 74.1% |
| `packkit/internal/lz4` | 27 | 29 | 0 | 48.2% |
| `packkit/internal/lz77` | 27 | 21 | 0 | 56.3% |
| `packkit/internal/lzma` | 192 | 52 | 3 | 78.9% |
| `packkit/internal/lzw` | 35 | 35 | 0 | 50.0% |
| `packkit/internal/snappy` | 22 | 43 | 0 | 33.8% |
| `packkit/internal/tar` | 38 | 23 | 0 | 62.3% |
| `packkit/internal/xxh32` | 10 | 0 | 0 | 100.0% |
| `packkit/internal/xz` | 73 | 20 | 0 | 78.5% |
| `packkit/internal/zlib` | 9 | 0 | 0 | 100.0% |
| `packkit/internal/zstd` | 113 | 244 | 0 | 31.7% |
| `packkit/seven_z` | 156 | 112 | 0 | 58.2% |
| `packkit/zip` | 109 | 158 | 0 | 40.8% |
| all | 1852 | 1250 | 4 | 59.8% |
<!-- mutation:end -->
