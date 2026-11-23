//// Every reader and every codec checks every field of `Limits` that
//// applies to it. Each test builds a valid input, tightens one field
//// just below what the input needs, and expects `LimitExceeded` naming
//// that field. The tests collect every cell that misbehaves, so one
//// failure shows the whole gap.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import packkit
import packkit/archive.{type Archive, type ArchiveFormat, Archive}
import packkit/codec.{type Codec}
import packkit/limit.{type Limits, Limits}
import packkit/seven_z
import packkit/zip

const body_size = 1000

fn sample(format: ArchiveFormat) -> Archive {
  let body = bit_array.from_string(string.repeat("packkit ", body_size / 8))
  Archive(
    format:,
    entries: [
      archive.new_entry(path: "a/b/c/long-name.txt", kind: archive.File(body)),
      archive.new_entry(path: "x.txt", kind: archive.File(body)),
    ],
    comment: None,
  )
}

// Each field set just below what `sample` needs, with the name the
// error must carry.
fn tight(input_size: Int) -> List(#(String, Limits)) {
  let base = limit.default()
  [
    #("max_input_bytes", Limits(..base, max_input_bytes: input_size - 1)),
    #("max_output_bytes", Limits(..base, max_output_bytes: body_size + 10)),
    #("max_members", Limits(..base, max_members: 1)),
    #("max_entry_name_bytes", Limits(..base, max_entry_name_bytes: 10)),
    #("max_entry_depth", Limits(..base, max_entry_depth: 3)),
  ]
}

fn check_archive(
  label: String,
  bytes: BitArray,
  decode: fn(Limits) -> Result(Archive, archive.ArchiveError),
) -> List(String) {
  let assert Ok(_) = decode(limit.default())
  tight(bit_array.byte_size(bytes))
  |> list.filter_map(fn(cell) {
    let #(name, limits) = cell
    case decode(limits) {
      Error(archive.LimitExceeded(limit: got, actual: _)) if got == name ->
        Error(Nil)
      other -> Ok(label <> " " <> name <> ": " <> describe(other))
    }
  })
}

pub fn archive_readers_enforce_every_limit_test() -> Nil {
  let plain =
    [archive.Tar, archive.Cpio, archive.Ar, archive.Zip, archive.SevenZ]
    |> list.flat_map(fn(format) {
      let assert Ok(bytes) = packkit.write(sample(format))
      check_archive(archive.format_to_string(format), bytes, fn(limits) {
        packkit.read_with_limits(bytes, format:, limits:)
      })
    })
  let zip_methods =
    [zip.Store, zip.Deflate, zip.Bzip2, zip.Lzma, zip.Zstd, zip.Xz]
    |> list.flat_map(fn(method) {
      let assert Ok(bytes) = zip.encode(sample(archive.Zip), method:)
      check_archive("zip " <> string.inspect(method), bytes, fn(limits) {
        zip.decode(bytes:, limits:)
      })
    })
  let seven_z_methods =
    [seven_z.Lzma, seven_z.Copy, seven_z.Deflate, seven_z.Bzip2]
    |> list.flat_map(fn(method) {
      let assert Ok(bytes) =
        seven_z.encode(
          sample(archive.SevenZ),
          method:,
          encryption: seven_z.Unencrypted,
        )
      check_archive("7z " <> string.inspect(method), bytes, fn(limits) {
        seven_z.decode(bytes:, limits:)
      })
    })
  assert list.flatten([plain, zip_methods, seven_z_methods]) == []
}

// Each decode of an encrypted 7z runs the key derivation, so these use
// one method and one test per encryption mode to stay fast.

pub fn seven_z_encrypted_contents_enforce_every_limit_test() -> Nil {
  check_encrypted_seven_z(seven_z.EncryptContents("pw"))
}

pub fn seven_z_encrypted_headers_enforce_every_limit_test() -> Nil {
  check_encrypted_seven_z(seven_z.EncryptContentsAndHeaders("pw"))
}

fn check_encrypted_seven_z(encryption: seven_z.Encryption) -> Nil {
  let assert Ok(bytes) =
    seven_z.encode(sample(archive.SevenZ), method: seven_z.Copy, encryption:)
  let failures =
    check_archive(string.inspect(encryption), bytes, fn(limits) {
      seven_z.decode_with_password(bytes:, password: "pw", limits:)
    })
  assert failures == []
}

pub fn codecs_enforce_input_and_output_limits_test() -> Nil {
  let plain = bit_array.from_string(string.repeat("packkit ", 500))
  let failures =
    [
      codec.Identity,
      codec.Deflate,
      codec.Zlib,
      codec.Gzip,
      codec.Lz4,
      codec.Snappy,
      codec.Bzip2,
      codec.Lzw,
      codec.Xz,
      codec.Zstd,
      codec.Brotli,
    ]
    |> list.flat_map(fn(codec: Codec) {
      let assert Ok(packed) = packkit.compress(plain, with: codec)
      let base = limit.default()
      let cells = [
        #(
          "max_input_bytes",
          Limits(..base, max_input_bytes: bit_array.byte_size(packed) - 1),
        ),
        #(
          "max_output_bytes",
          Limits(..base, max_output_bytes: bit_array.byte_size(plain) - 1),
        ),
      ]
      list.filter_map(cells, fn(cell) {
        let #(name, limits) = cell
        case packkit.decompress_with_limits(packed, with: codec, limits:) {
          Error(codec.LimitExceeded(limit: got, actual: _)) if got == name ->
            Error(Nil)
          other ->
            Ok(
              string.inspect(codec)
              <> " "
              <> name
              <> " ("
              <> int.to_string(bit_array.byte_size(packed))
              <> " bytes): "
              <> describe(other),
            )
        }
      })
    })
  assert failures == []
}

fn describe(result: Result(a, e)) -> String {
  case result {
    Ok(_) -> "Ok"
    Error(error) -> string.inspect(error)
  }
}
