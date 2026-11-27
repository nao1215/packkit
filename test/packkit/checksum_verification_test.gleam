//// Decoders must check the checksums a stream carries, so a flipped
//// byte returns `InvalidData` instead of different output.

import gleam/bit_array
import packkit
import packkit/codec

fn flip(bytes: BitArray, at: Int) -> BitArray {
  let assert <<head:bytes-size(at), byte, tail:bytes>> = bytes
  <<head:bits, { 255 - byte }, tail:bits>>
}

fn is_invalid(result: Result(a, codec.CodecError)) -> Bool {
  case result {
    Error(codec.InvalidData(_)) -> True
    _ -> False
  }
}

// `lz4.encode(Buffer.from("hello"))` from the `lz4` npm package: the
// header checksum is byte 6, the literal "hello" bytes 12 to 16, and the
// content checksum the last 4 bytes.
const lz4_hello = <<
  0x04, 0x22, 0x4d, 0x18, 0x64, 0x70, 0xb9, 0x06, 0x00, 0x00, 0x00, 0x50, 0x68,
  0x65, 0x6c, 0x6c, 0x6f, 0x00, 0x00, 0x00, 0x00, 0xf9, 0x77, 0x00, 0xfb,
>>

pub fn lz4_golden_frame_decodes_test() -> Nil {
  assert packkit.decompress(lz4_hello, with: codec.Lz4) == Ok(<<"hello">>)
}

pub fn lz4_rejects_wrong_header_checksum_test() -> Nil {
  assert is_invalid(packkit.decompress(flip(lz4_hello, 6), with: codec.Lz4))
}

pub fn lz4_rejects_wrong_content_checksum_test() -> Nil {
  assert is_invalid(packkit.decompress(flip(lz4_hello, 24), with: codec.Lz4))
}

pub fn lz4_rejects_changed_payload_test() -> Nil {
  assert is_invalid(packkit.decompress(flip(lz4_hello, 14), with: codec.Lz4))
}

pub fn snappy_rejects_wrong_chunk_crc_test() -> Nil {
  let assert Ok(packed) =
    packkit.compress(<<"hello, snappy">>, with: codec.Snappy)
  // The stream identifier takes 10 bytes and the chunk header 4, so the
  // masked CRC-32C of the first chunk starts at byte 14.
  assert bit_array.byte_size(packed) > 18
  assert is_invalid(packkit.decompress(flip(packed, 14), with: codec.Snappy))
}

pub fn snappy_rejects_changed_payload_test() -> Nil {
  let assert Ok(packed) =
    packkit.compress(<<"hello, snappy">>, with: codec.Snappy)
  let last = bit_array.byte_size(packed) - 1
  assert is_invalid(packkit.decompress(flip(packed, last), with: codec.Snappy))
}

// `printf 'hello, zstd' | zstd -c --check`: the frame descriptor sets
// the Content_Checksum flag, one raw block carries the 11 literal bytes
// at 9 to 19, and the last 4 bytes hold the low 32 bits of XXH64.
const zstd_hello = <<
  0x28, 0xb5, 0x2f, 0xfd, 0x04, 0x58, 0x59, 0x00, 0x00, 0x68, 0x65, 0x6c, 0x6c,
  0x6f, 0x2c, 0x20, 0x7a, 0x73, 0x74, 0x64, 0x78, 0x96, 0x21, 0x3c,
>>

// The same payload with `zstd -c --no-check`: no checksum flag and no
// trailing checksum.
const zstd_hello_unchecked = <<
  0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x58, 0x59, 0x00, 0x00, 0x68, 0x65, 0x6c, 0x6c,
  0x6f, 0x2c, 0x20, 0x7a, 0x73, 0x74, 0x64,
>>

// `"abc" × 60 | zstd -c --check`: a compressed block with one sequence.
const zstd_abc_cycle = <<
  0x28, 0xb5, 0x2f, 0xfd, 0x04, 0x58, 0x55, 0x00, 0x00, 0x18, 0x61, 0x62, 0x63,
  0x01, 0x00, 0x2e, 0x29, 0x37, 0x04, 0xb0, 0x59, 0x38, 0x7f,
>>

// `printf 'second frame' | zstd -c --check`.
const zstd_second = <<
  0x28, 0xb5, 0x2f, 0xfd, 0x04, 0x58, 0x61, 0x00, 0x00, 0x73, 0x65, 0x63, 0x6f,
  0x6e, 0x64, 0x20, 0x66, 0x72, 0x61, 0x6d, 0x65, 0x17, 0x64, 0x07, 0xb6,
>>

pub fn zstd_golden_frames_decode_test() -> Nil {
  assert packkit.decompress(zstd_hello, with: codec.Zstd)
    == Ok(<<"hello, zstd">>)
  assert packkit.decompress(zstd_hello_unchecked, with: codec.Zstd)
    == Ok(<<"hello, zstd">>)
  let assert Ok(abc) = packkit.decompress(zstd_abc_cycle, with: codec.Zstd)
  assert bit_array.byte_size(abc) == 180
  assert packkit.decompress(
      bit_array.concat([zstd_hello, zstd_second]),
      with: codec.Zstd,
    )
    == Ok(<<"hello, zstdsecond frame">>)
}

pub fn zstd_rejects_wrong_content_checksum_test() -> Nil {
  assert is_invalid(packkit.decompress(flip(zstd_hello, 20), with: codec.Zstd))
  assert is_invalid(packkit.decompress(flip(zstd_hello, 23), with: codec.Zstd))
  assert is_invalid(packkit.decompress(
    flip(zstd_abc_cycle, 22),
    with: codec.Zstd,
  ))
}

pub fn zstd_rejects_changed_raw_literal_test() -> Nil {
  assert is_invalid(packkit.decompress(flip(zstd_hello, 12), with: codec.Zstd))
}

pub fn zstd_rejects_wrong_checksum_in_a_later_frame_test() -> Nil {
  let stream = bit_array.concat([zstd_hello, flip(zstd_second, 24)])
  assert is_invalid(packkit.decompress(stream, with: codec.Zstd))
}

pub fn zstd_without_checksum_flag_skips_the_check_test() -> Nil {
  // Nothing in the frame can show the change, so the decoder returns it.
  assert packkit.decompress(flip(zstd_hello_unchecked, 12), with: codec.Zstd)
    == Ok(<<"hel", { 255 - 0x6c }, "o, zstd">>)
  // packkit's own encoder writes frames without the checksum flag.
  let assert Ok(packed) = packkit.compress(<<"hello, zstd">>, with: codec.Zstd)
  assert packkit.decompress(packed, with: codec.Zstd) == Ok(<<"hello, zstd">>)
}
