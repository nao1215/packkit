import gleeunit/should
import packkit/internal/lzma

pub fn properties_default_xz_test() -> Nil {
  let assert Ok(props) = lzma.properties_of_byte(0x5D)
  props
  |> should.equal(lzma.Properties(lc: 3, lp: 0, pb: 2))
}

pub fn decode_repeated_byte_lzma_test() -> Nil {
  // LZMA payload from `printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' | xz -c`,
  // namely the 7 bytes after the properties byte 0x5D.
  let lzma_data = <<0x00, 0x30, 0xEE, 0x12, 0x00, 0x00, 0x00>>
  let assert Ok(decoder) =
    lzma.new(lzma_data, lzma.Properties(lc: 3, lp: 0, pb: 2), 200)
  let assert Ok(#(bytes, _state)) = lzma.decode_into(decoder, 30)
  bytes
  |> should.equal(<<"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa":utf8>>)
}
