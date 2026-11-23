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
