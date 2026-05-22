# packkit

`packkit` is a spec-first Gleam library for archive, compression, and
container workflows on the Erlang and JavaScript targets.

The repository now contains:

- a compileable cross-target project scaffold
- an opaque-first public API skeleton
- a detailed implementation spec for follow-up LLM or human work

Most encode/decode operations are intentionally stubbed and currently
return typed `*NotImplemented` errors. That is deliberate: the goal of
this first step is to lock in the API shape, safety model, module
boundaries, and implementation order before the heavy codec work begins.

## Design stance

`packkit` treats these as different concepts:

- **codec**: bytes in, bytes out (`gzip`, `zlib`, `deflate`, `lz4`, ...)
- **archive**: entries in, bytes out (`tar`, `zip`, `cpio`, `7z`, ...)
- **recipe**: one archive plus zero or more outer codecs (`tar.gz`,
  `tar.lz4`, `cpio.zst`, ...)

`zip` and `7z` stay in the archive family. They are not modelled as
recipes just because they may compress their members internally.

## Status

- Path-safe `Entry` constructors are implemented.
- `Codec`, `ArchiveFormat`, `Archive`, `Recipe`, `Limits`, and
  `Detected` are opaque and documented.
- Filename-based detection works for common extensions.
- The implementation roadmap lives in
  [`doc/reference/spec.md`](doc/reference/spec.md).

## Install

```sh
gleam add packkit
```

## Current examples

The constructors already work and are intended to be the stable shape
future implementations fill in:

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

The actual archive and codec engines are still pending, so calls such as
`packkit.pack`, `packkit.unpack`, `packkit.compress`, and
`packkit.decompress` currently return typed `NotImplemented` errors.

## Development

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the local workflow and
[`doc/reference/spec.md`](doc/reference/spec.md) for the architecture
and implementation order.
