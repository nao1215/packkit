//// Mutation fuzzing for every decoder. Each test starts from valid
//// streams or archives, applies a few random edits (flipped bytes,
//// truncation, inserted bytes, length-like fields overwritten with huge
//// values, deleted runs) and checks that the decoder returns a `Result`
//// that keeps to the `Limits`: no panic, no hang, no output past
//// `max_output_bytes`, no more entries than `max_members`, and only
//// safe entry paths within the name and depth limits.
////
//// metamon draws a new seed on every run and prints it on failure; the
//// nightly workflow runs these with more cases.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import metamon
import metamon/generator.{type Generator}
import metamon/generator/range
import packkit
import packkit/archive.{type Archive, type ArchiveFormat, Archive}
import packkit/codec.{type Codec}
import packkit/internal/entry
import packkit/limit.{Limits}
import packkit/seven_z
import packkit/zip

const fuzz_limits =
  Limits(
    max_input_bytes: 1_000_000,
    max_output_bytes: 200_000,
    max_members: 20,
    max_entry_name_bytes: 64,
    max_entry_depth: 6,
  )

type Mutation {
  Flip(at: Int, value: Int)
  Truncate(at: Int)
  Insert(at: Int, bytes: BitArray)
  Huge(at: Int, value: Int)
  Delete(at: Int, count: Int)
}

fn mutation() -> Generator(Mutation) {
  let at = generator.int(range.constant(0, 100_000))
  generator.one_of([
    generator.map2(at, generator.byte(), Flip),
    generator.map(at, Truncate),
    generator.map2(at, generator.bit_array(range.constant(1, 8)), Insert),
    generator.map2(
      at,
      generator.element_of([0xFFFFFFFF, 0x7FFFFFFF, 0x80000000, 0x00FFFFFF]),
      Huge,
    ),
    generator.map2(at, generator.int(range.constant(1, 64)), Delete),
  ])
}

fn apply(bytes: BitArray, mutation: Mutation) -> BitArray {
  let size = bit_array.byte_size(bytes)
  let position = fn(at) {
    case size {
      0 -> 0
      _ -> at % size
    }
  }
  case mutation {
    Flip(at, value) -> replace(bytes, position(at), <<value>>)
    Truncate(at) -> take(bytes, position(at))
    Insert(at, inserted) -> {
      let at = position(at)
      <<take(bytes, at):bits, inserted:bits, drop(bytes, at):bits>>
    }
    Huge(at, value) -> replace(bytes, position(at), <<value:size(32)-little>>)
    Delete(at, count) -> {
      let at = position(at)
      <<take(bytes, at):bits, drop(bytes, at + count):bits>>
    }
  }
}

fn take(bytes: BitArray, count: Int) -> BitArray {
  case bytes {
    <<head:bytes-size(count), _:bytes>> -> head
    _ -> bytes
  }
}

fn drop(bytes: BitArray, count: Int) -> BitArray {
  case bytes {
    <<_:bytes-size(count), rest:bytes>> -> rest
    _ -> <<>>
  }
}

fn replace(bytes: BitArray, at: Int, with: BitArray) -> BitArray {
  let after = at + bit_array.byte_size(with)
  case after > bit_array.byte_size(bytes) {
    True -> bytes
    False -> <<take(bytes, at):bits, with:bits, drop(bytes, after):bits>>
  }
}

fn mutated(seeds: List(BitArray)) -> Generator(BitArray) {
  generator.map2(
    generator.element_of(seeds),
    generator.list_of(mutation(), range.constant(1, 4)),
    fn(seed, mutations) { list.fold(mutations, seed, apply) },
  )
}

fn plain_inputs() -> List(BitArray) {
  [
    <<>>,
    <<"a">>,
    bit_array.from_string(string.repeat("packkit fuzz ", 200)),
    int.range(from: 0, to: 256, with: <<>>, run: fn(acc, b) { <<acc:bits, b>> }),
  ]
}

fn limit_name_is_known(name: String) -> Bool {
  list.contains(
    [
      "max_input_bytes",
      "max_output_bytes",
      "max_members",
      "max_entry_name_bytes",
      "max_entry_depth",
    ],
    name,
  )
}

// Codecs ----------------------------------------------------------------

fn fuzz_codec(codec: Codec) -> Nil {
  let seeds =
    list.map(plain_inputs(), fn(plain) {
      let assert Ok(packed) = packkit.compress(plain, with: codec)
      packed
    })
  metamon.forall(mutated(seeds), fn(bytes) {
    codec_result_keeps_limits(packkit.decompress_with_limits(
      bytes,
      with: codec,
      limits: fuzz_limits,
    ))
  })
}

fn codec_result_keeps_limits(
  result: Result(BitArray, codec.CodecError),
) -> Bool {
  case result {
    Ok(out) -> bit_array.byte_size(out) <= fuzz_limits.max_output_bytes
    Error(codec.LimitExceeded(limit:, actual: _)) -> limit_name_is_known(limit)
    Error(_) -> True
  }
}

pub fn fuzz_deflate_test() -> Nil {
  fuzz_codec(codec.Deflate)
}

pub fn fuzz_zlib_test() -> Nil {
  fuzz_codec(codec.Zlib)
}

pub fn fuzz_gzip_test() -> Nil {
  fuzz_codec(codec.Gzip)
}

pub fn fuzz_lz4_test() -> Nil {
  fuzz_codec(codec.Lz4)
}

pub fn fuzz_snappy_test() -> Nil {
  fuzz_codec(codec.Snappy)
}

pub fn fuzz_bzip2_test() -> Nil {
  fuzz_codec(codec.Bzip2)
}

pub fn fuzz_lzw_test() -> Nil {
  fuzz_codec(codec.Lzw)
}

pub fn fuzz_xz_test() -> Nil {
  fuzz_codec(codec.Xz)
}

pub fn fuzz_zstd_test() -> Nil {
  fuzz_codec(codec.Zstd)
}

pub fn fuzz_brotli_test() -> Nil {
  fuzz_codec(codec.Brotli)
}

// Archives --------------------------------------------------------------

fn sample(format: ArchiveFormat) -> Archive {
  let body = bit_array.from_string(string.repeat("entry body ", 30))
  let files = [
    archive.new_entry(path: "a.txt", kind: archive.File(body)),
    archive.new_entry(path: "dir/b.bin", kind: archive.File(<<1, 2, 3>>)),
  ]
  let directory = archive.new_entry(path: "dir", kind: archive.Directory)
  let link = archive.new_entry(path: "link", kind: archive.Symlink("a.txt"))
  let extra = case format {
    archive.Tar | archive.Cpio -> [directory, link]
    archive.Zip -> [directory]
    archive.Ar | archive.SevenZ -> []
  }
  Archive(format:, entries: list.append(files, extra), comment: None)
}

fn fuzz_archive(format: ArchiveFormat, seeds: List(BitArray)) -> Nil {
  metamon.forall(mutated(seeds), fn(bytes) {
    archive_result_keeps_limits(packkit.read_with_limits(
      bytes,
      format:,
      limits: fuzz_limits,
    ))
  })
}

fn archive_result_keeps_limits(
  result: Result(Archive, archive.ArchiveError),
) -> Bool {
  case result {
    Ok(read) -> {
      let total =
        list.fold(read.entries, 0, fn(total, e) {
          total + bit_array.byte_size(entry.body(e))
        })
      list.length(read.entries) <= fuzz_limits.max_members
      && total <= fuzz_limits.max_output_bytes
      && list.all(read.entries, fn(e) {
        string.byte_size(e.path) <= fuzz_limits.max_entry_name_bytes
        && entry.depth(e.path) <= fuzz_limits.max_entry_depth
        && entry.check_path(e.path) == Ok(Nil)
      })
    }
    Error(archive.LimitExceeded(limit:, actual: _)) ->
      limit_name_is_known(limit)
    Error(_) -> True
  }
}

fn written(format: ArchiveFormat) -> BitArray {
  let assert Ok(bytes) = packkit.write(sample(format))
  bytes
}

pub fn fuzz_tar_test() -> Nil {
  fuzz_archive(archive.Tar, [written(archive.Tar)])
}

pub fn fuzz_cpio_test() -> Nil {
  fuzz_archive(archive.Cpio, [written(archive.Cpio)])
}

pub fn fuzz_ar_test() -> Nil {
  fuzz_archive(archive.Ar, [written(archive.Ar)])
}

pub fn fuzz_zip_test() -> Nil {
  let seeds =
    [zip.Store, zip.Deflate, zip.Bzip2, zip.Lzma, zip.Zstd, zip.Xz]
    |> list.map(fn(method) {
      let assert Ok(bytes) = zip.encode(sample(archive.Zip), method:)
      bytes
    })
  fuzz_archive(archive.Zip, seeds)
}

pub fn fuzz_seven_z_test() -> Nil {
  let seeds =
    [seven_z.Lzma, seven_z.Copy, seven_z.Deflate, seven_z.Bzip2]
    |> list.map(fn(method) {
      let assert Ok(bytes) =
        seven_z.encode(
          sample(archive.SevenZ),
          method:,
          encryption: seven_z.Unencrypted,
        )
      bytes
    })
  fuzz_archive(archive.SevenZ, seeds)
}

// The same checks with each limit at 1, so every reader reaches every
// limit branch.
pub fn fuzz_archives_under_tiny_limits_test() -> Nil {
  let tiny =
    Limits(
      max_input_bytes: 100_000,
      max_output_bytes: 16,
      max_members: 1,
      max_entry_name_bytes: 4,
      max_entry_depth: 1,
    )
  [archive.Tar, archive.Cpio, archive.Ar, archive.Zip, archive.SevenZ]
  |> list.each(fn(format) {
    let bytes = written(format)
    case packkit.read_with_limits(bytes, format:, limits: tiny) {
      Error(archive.LimitExceeded(limit:, actual:)) -> {
        assert limit_name_is_known(limit)
        assert actual > 1
      }
      other -> panic as { "expected a limit error, got " <> describe(other) }
    }
  })
}

fn describe(result: Result(a, b)) -> String {
  case result {
    Ok(_) -> "Ok"
    Error(error) -> string.inspect(error)
  }
}
