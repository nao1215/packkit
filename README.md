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

- **checksum**: Adler-32 and CRC-32
- **tar**: USTAR encode/decode (regular files, directories, symlinks,
  hardlinks, prefix/name split)
- **cpio**: newc encode/decode
- **ar**: BSD long-name encode/decode
- **zip**: stored-method encode/decode with CRC-32 verification
- **deflate**: full RFC 1951 decoder (stored, fixed, dynamic Huffman);
  encoder currently emits stored blocks only
- **zlib**: RFC 1950 wrapper with Adler-32 trailer
- **gzip**: RFC 1952 wrapper with header metadata and CRC/ISIZE
  verification

The facade (`packkit.compress`, `packkit.decompress`, `packkit.read`,
`packkit.write`, `packkit.pack`, `packkit.unpack`) is wired to these
engines.  Filename- and byte-signature-based detection are both
available.

Pending codecs (`lz4`, `snappy`, `bzip2`, `xz`, `brotli`, `zstd`),
`7z`, ZIP deflate method, and a Huffman-coded DEFLATE encoder return
typed `*NotImplemented` errors.

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
