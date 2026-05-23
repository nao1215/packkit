import gleeunit/should
import packkit/codec
import packkit/error
import packkit/zstd

pub fn codec_marker_test() -> Nil {
  zstd.codec()
  |> codec.name
  |> should.equal("zstd")
}

pub fn encode_reports_not_implemented_test() -> Nil {
  zstd.encode(bytes: <<>>)
  |> should.equal(Error(error.CodecNotImplemented(feature: "zstd.encode")))
}

pub fn decode_raw_block_hi_test() -> Nil {
  // `printf 'hi' | zstd -c` — frame with one raw block + checksum.
  let fixture = <<
    0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x58, 0x11, 0x00, 0x00, 0x68, 0x69, 0xFA, 0x38,
    0x26, 0xEA,
  >>
  let assert Ok(plain) = zstd.decode(bytes: fixture)
  plain
  |> should.equal(<<"hi":utf8>>)
}

pub fn decode_raw_block_abc_test() -> Nil {
  // `printf 'abc' | zstd -c`.
  let fixture = <<
    0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x58, 0x19, 0x00, 0x00, 0x61, 0x62, 0x63, 0x99,
    0x09, 0x77, 0xAD,
  >>
  let assert Ok(plain) = zstd.decode(bytes: fixture)
  plain
  |> should.equal(<<"abc":utf8>>)
}

pub fn decode_compressed_block_pending_test() -> Nil {
  // `printf 'aa...aa' | zstd -c` — uses block type 2 (compressed).
  let fixture = <<
    0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x58, 0x45, 0x00, 0x00, 0x10, 0x61, 0x61, 0x01,
    0x00, 0x1E, 0xC0, 0x02, 0xF7, 0xAF, 0x47, 0xE3,
  >>
  case zstd.decode(bytes: fixture) {
    Error(error.CodecNotImplemented(feature: f)) ->
      f
      |> should.equal("zstd compressed blocks (FSE + Huffman)")
    other -> {
      other
      |> should.equal(
        Error(error.CodecNotImplemented(
          feature: "zstd compressed blocks (FSE + Huffman)",
        )),
      )
    }
  }
}

pub fn decode_rejects_missing_magic_test() -> Nil {
  zstd.decode(bytes: <<0x00, 0x00, 0x00, 0x00>>)
  |> should.equal(
    Error(error.CodecInvalidData(message: "missing zstd frame magic")),
  )
}
