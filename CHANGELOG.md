# Changelog

## Unreleased

- Fixed an LZW decoder width-promote off-by-one bug that injected a
  phantom `0` byte into round trips of the 256-byte sequence
  `[0..255]`.  The encoder pads to the 9-bit byte-block boundary
  right after writing code 254, but the decoder's promote check used
  `free_ent > max_code`, which fires one iteration too late given
  LZW's classical encoder/decoder insert-pair asymmetry; the new
  `>=` check promotes between codes 254 and 255 to match the
  encoder.  Added regression tests at the promote boundary ±1 to
  guard against re-introducing the bug.  See
  [packkit/lzw.promote_decoder_width].
- Extended `packkit/stream` to cover every codec uniformly.
  Previously only DEFLATE, zlib, and gzip had streaming decoders;
  added `new_lz4_decoder`, `new_snappy_decoder`, `new_bzip2_decoder`,
  `new_lzw_decoder`, `new_xz_decoder`, `new_zstd_decoder`, and
  `new_brotli_decoder` so the streaming surface is consistent across
  all ten supported codecs.
- Added metamon-driven property-based round-trip tests
  (`test/packkit/property_test.gleam`) over every codec for arbitrary
  `BitArray` inputs in the 0..256-byte range, plus length-preservation
  invariants for DEFLATE and LZW.  Together with the existing
  fixture-based round-trip tests this materially widens coverage at
  the empty-input, single-byte, and width-promote / window
  boundaries that have historically been failure-prone.
- Added panic-free fuzz tests for `seven_z.decode/1`
  (`test/packkit/seven_z_fuzz_test.gleam`) covering empty, partial
  signature, garbage, alternating, all-zeros, all-`FF`, and counter
  inputs so a future regression that panics on a malformed 7z stream
  fails noisily instead of silently propagating.
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
- Added the Brotli command loop with the I+C alphabet (`kCmdLut`
  port), the 4-entry recent-distance ring buffer, and self-
  overlapping LZ77 copies; end-to-end round-trip works for
  `aaa…` / `time of the day` / `Hello, World!` style fixtures.
- Embedded the RFC 7932 122,784-byte static dictionary and ported
  the 121-entry transform table (IDENTITY / OMIT_FIRST_n /
  OMIT_LAST_n / UPPERCASE_FIRST / UPPERCASE_ALL with the brotli
  "overly simplified" UTF-8 case rules; SHIFT_FIRST / SHIFT_ALL
  intentionally absent because the basic transform set never
  selects them).
- Added Brotli literal context-map decoding (§7.3): RLEMAX +
  zero-run-encoded prefix code + optional inverse MTF, plus the
  embedded 2 KiB `_kBrotliContextLookupTable` and the per-context
  literal/distance tree selection on every emission.
- Added Brotli block switching (§6) for the literal, insert-and-
  copy, and distance categories: each tracks its own block-type
  prefix code, the shared 26-symbol block-length alphabet, and a
  2-entry recent-type ring buffer that feeds back into context-map
  indexing.
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
- Honour the codec's `level` and preset `dictionary` in the facade.
  Unsupported combinations now surface the typed
  `CodecOptionUnsupported(option, codec_name)` instead of silently
  dropping the option.  Aligned `codec.bzip2()` with bzip2's
  canonical level 9 so `packkit.compress(b, codec.bzip2())` and
  `bzip2.encode(b)` produce identical output.
- Implemented zlib preset-dictionary support: `encode_with_dictionary`
  emits the FDICT envelope with the Adler-32 DICT_ID,
  `decode_with_dictionary` resolves it (with a typed
  `CodecDictionaryMismatch` on a wrong-key dictionary), and the
  decoder now enforces `Limits.max_window_bits` against the CMF
  CINFO field.
- Added safe gzip header constructors: `with_name_checked` /
  `with_comment_checked` reject the NUL byte that would silently
  truncate the FNAME / FCOMMENT field on round-trip.  The unchecked
  builders now strip embedded NULs.
- Tightened `detect.from_bytes`: gzip requires CM=8, zlib verifies
  CMF.CM/CINFO and the FCHECK mod-31 invariant (no more
  false-positives on `0x78 _` prefixes), bzip2 requires the 1..9
  block-size digit.
- Enforced `Limits.max_entry_depth` consistently across cpio, ar,
  zip, and 7z (it previously fired only on tar).
- Implemented `gzip.new_decoder` / `push` / `finish` as a buffered
  decoder so the streaming surface is no longer a typed
  `CodecNotImplemented`.  Mirrors the codec-neutral
  `packkit/stream` API.
- Implemented a real `brotli.encode` that emits valid uncompressed
  metablocks (RFC 7932 §9.2) followed by a terminating empty
  ISLAST marker.  `tar.brotli` now round-trips end-to-end through
  the facade.
