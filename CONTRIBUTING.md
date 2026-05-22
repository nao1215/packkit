# Contributing to packkit

## Development setup

You need the following tools installed:

- [Gleam](https://gleam.run/) 1.15+
- Erlang/OTP 28+
- Node.js 22+ for JavaScript-target builds and tests
- [just](https://github.com/casey/just) as a task runner
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
`scripts/lib/mise_bootstrap.sh`, so `mise activate` is not required in
the current shell.

## Project status

This repository is currently **spec-first**:

- the public API shape is present and compiles
- the safety model is defined
- many encode/decode operations still return typed
  `*NotImplemented` errors

Before implementing a new family, read
[`doc/reference/spec.md`](doc/reference/spec.md). That document is the
source of truth for module ownership, invariants, and implementation
order.

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

- `src/` contains the public library surface and the early scaffolding
  modules
- `test/` contains the `gleeunit` smoke tests
- `doc/reference/spec.md` is the implementation contract for future
  contributors
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
