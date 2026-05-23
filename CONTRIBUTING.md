# Contributing to packkit

## Development setup

You need the following tools installed:

- [Gleam](https://gleam.run/) 1.15+
- Erlang/OTP 28+
- Node.js 22+ for JavaScript-target builds and tests
- [just](https://github.com/casey/just) 1.14+ as a task runner — the
  `justfile` uses the `shell()` function which is parsed at justfile
  load time, so older `just` will fail before it can run any recipe.
- [mise](https://mise.jdx.dev/) for toolchain management

Clone the repository and install the managed toolchain:

```console
git clone https://github.com/nao1215/packkit.git
cd packkit
mise trust .mise.toml
mise install
just deps
```

`just` recipes and helper scripts locate the mise-managed toolchain via
`scripts/lib/mise_bootstrap.sh`, which the `justfile`'s `export PATH`
line sources at load time.  That means `mise activate` is not required
in the current shell, but the script and `mise` itself **must already
be reachable** when `just` parses the file — otherwise `just` fails
with a `shell` error before any recipe runs.  If that happens, source
the bootstrap script by hand once (`. scripts/lib/mise_bootstrap.sh`)
and re-run `just`.

## Project status

Implemented engines:

- **checksum**: Adler-32, CRC-32 (reflected), CRC-32C, bzip2 CRC-32.
- **tar / cpio (newc) / ar**: full encode/decode.
- **zip**: stored-method encode/decode; deflate-method encode/decode.
- **deflate**: full RFC 1951 decoder; fixed-Huffman LZ77 encoder.
- **zlib / gzip**: full RFC wrappers including preset-dictionary
  support on zlib's decoder side (and an `encode_with_dictionary`
  helper that emits the FDICT envelope).
- **lz4 / snappy / lzw**: full encode/decode.
- **bzip2**: full encode/decode (level 1..9).
- **xz**: full LZMA2 decoder (raw + LZMA-compressed chunks);
  uncompressed-LZMA2 encoder.
- **zstd**: frame envelope + raw + RLE + FSE-compressed blocks with
  Raw/RLE literals and predefined FSE modes on decode; raw-block
  encoder.
- **brotli**: full RFC 7932 decoder; encoder emits uncompressed
  metablocks only (valid stream, no actual compression yet).
- **7z**: single-folder LZMA / LZMA2 reader; encoder still pending.

Codecs without real encoders (`xz`, `zstd`, `brotli`) still produce
valid streams that any conforming decoder accepts; they just do no
actual compression yet.  The `*NotImplemented` errors that remain are
either internal helpers or 7z encode.

The facade (`packkit.compress`, `packkit.decompress`, `packkit.pack`,
`packkit.unpack`) honours the codec's optional `level` and preset
dictionary.  Asking for an option the underlying engine cannot honour
returns the typed `CodecOptionUnsupported` instead of silently
dropping the request.

## Running checks

Run the full local check with:

```console
just ci
```

You can also run individual steps:

| Command | Effect |
| --- | --- |
| `just format` | Reformat `src/` and `test/` |
| `just format-check` | Fail on formatting drift |
| `just typecheck` | `gleam check` |
| `just lint` | Run `glinter` with warnings as errors |
| `just build-erlang` / `just build-javascript` | Per-target build |
| `just test-erlang` / `just test-javascript` | Per-target test |
| `just docs` | Build HexDocs HTML |
| `just clean` | Delete `build/` |

## Project structure

- `src/` contains the public library surface and codec engines
- `test/` contains the `gleeunit` unit tests
- `scripts/lib/mise_bootstrap.sh` makes the mise-managed toolchain
  visible to `just` and shell scripts

## Code style

- Run `gleam format src/ test/` before committing.
- The build uses `--warnings-as-errors`; fix all warnings.
- `glinter` runs in `warnings_as_errors` mode.
- Public API requires doc comments.
- Prefer pure Gleam over target-specific FFI.
- Keep Erlang and JavaScript behavior aligned unless a target-specific
  difference is explicitly documented in the spec.
- Keep `Codec`, `ArchiveFormat`, `Archive`, `Entry`, `Recipe`,
  `Detected`, `Limits`, and family-specific builders opaque unless the
  spec is intentionally revised.

## Testing expectations

- Add unit tests for new public behavior.
- Run target-neutral tests on both Erlang and JavaScript targets.
- Add regression tests for malformed inputs and limit enforcement.
- When implementing a codec or archive family, add both fixture tests
  and round-trip property tests.

## Pull request expectations

- All CI-equivalent checks must pass (`just ci`).
- Include tests for new behavior.
- Use [Conventional Commits](https://www.conventionalcommits.org/) for
  commit messages (`feat:`, `fix:`, `docs:`, `ci:`, `chore:`, ...).
- One logical change per pull request.

## License

Contributions to this project are considered to be released under the
project license (MIT).
