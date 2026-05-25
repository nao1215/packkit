import gleam/bit_array
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

pub fn properties_byte_roundtrips_test() -> Nil {
  // Every valid (lc + lp ≤ 4, pb ≤ 4) properties byte must survive
  // properties_of_byte / properties_to_byte.
  let assert Ok(props) = lzma.properties_of_byte(0x5D)
  lzma.properties_to_byte(props) |> should.equal(0x5D)
  let assert Ok(props_min) = lzma.properties_of_byte(0x00)
  lzma.properties_to_byte(props_min) |> should.equal(0x00)
}

pub fn encode_literal_only_self_roundtrips_short_test() -> Nil {
  // Smallest possible literal stream: a single byte.
  let props = lzma.Properties(lc: 3, lp: 0, pb: 2)
  let payload = <<0x42>>
  let encoded = lzma.encode_literal_only(bytes: payload, props: props)
  let assert Ok(decoder) = lzma.new(encoded, props, 1024)
  let assert Ok(#(decoded, _state)) =
    lzma.decode_into(decoder, bit_array.byte_size(payload))
  decoded |> should.equal(payload)
}

pub fn encode_literal_only_self_roundtrips_ascii_test() -> Nil {
  // A few words of ASCII to exercise multiple normalize cycles and
  // exactly the literal-context indexing the LZMA decoder uses.
  let props = lzma.Properties(lc: 3, lp: 0, pb: 2)
  let payload = <<"the quick brown fox jumps over the lazy dog":utf8>>
  let encoded = lzma.encode_literal_only(bytes: payload, props: props)
  let assert Ok(decoder) = lzma.new(encoded, props, 4096)
  let assert Ok(#(decoded, _state)) =
    lzma.decode_into(decoder, bit_array.byte_size(payload))
  decoded |> should.equal(payload)
}

pub fn encode_literal_only_self_roundtrips_with_zero_bytes_test() -> Nil {
  // Zero bytes are an easy corner case because the decoder's
  // `previous_output_byte` defaults to 0 for the first literal.
  let props = lzma.Properties(lc: 3, lp: 0, pb: 2)
  let payload = <<0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF>>
  let encoded = lzma.encode_literal_only(bytes: payload, props: props)
  let assert Ok(decoder) = lzma.new(encoded, props, 1024)
  let assert Ok(#(decoded, _state)) =
    lzma.decode_into(decoder, bit_array.byte_size(payload))
  decoded |> should.equal(payload)
}

pub fn encode_literal_only_long_payload_test() -> Nil {
  // Longer payload to make sure the range coder's shift_low cache
  // (deferred-carry chain) survives many encode_bit iterations
  // without losing bits.
  let props = lzma.Properties(lc: 3, lp: 0, pb: 2)
  let payload = repeat_bytes(<<"PACKKIT.LZMA.LITERAL.ENCODER.":utf8>>, 30)
  let encoded = lzma.encode_literal_only(bytes: payload, props: props)
  let assert Ok(decoder) = lzma.new(encoded, props, 16_384)
  let assert Ok(#(decoded, _state)) =
    lzma.decode_into(decoder, bit_array.byte_size(payload))
  decoded |> should.equal(payload)
}

pub fn encode_with_lz77_roundtrips_repetitive_test() -> Nil {
  // The classic test: highly repetitive input should round-trip
  // through the LZ77 match path AND come out smaller than the
  // literal-only encoding.
  let props = lzma.Properties(lc: 3, lp: 0, pb: 2)
  let payload = repeat_bytes(<<"PACKKIT-LZ77-DEMO-":utf8>>, 50)
  let lz77 = lzma.encode_with_lz77(bytes: payload, props: props)
  let literal_only = lzma.encode_literal_only(bytes: payload, props: props)
  let assert Ok(decoder) = lzma.new(lz77, props, 8192)
  let assert Ok(#(decoded, _state)) =
    lzma.decode_into(decoder, bit_array.byte_size(payload))
  decoded |> should.equal(payload)
  // LZ77 must beat literal-only by a wide margin on repeated input.
  let lz_size = bit_array.byte_size(lz77)
  let lit_size = bit_array.byte_size(literal_only)
  case lz_size * 2 < lit_size {
    True -> Nil
    False -> should.fail()
  }
}

pub fn encode_with_lz77_roundtrips_short_test() -> Nil {
  // Inputs shorter than the 3-byte minimum match can never produce
  // an LZMA match — the encoder must fall back to literals and still
  // round-trip.
  let props = lzma.Properties(lc: 3, lp: 0, pb: 2)
  let payload = <<0x42, 0x43>>
  let encoded = lzma.encode_with_lz77(bytes: payload, props: props)
  let assert Ok(decoder) = lzma.new(encoded, props, 1024)
  let assert Ok(#(decoded, _state)) =
    lzma.decode_into(decoder, bit_array.byte_size(payload))
  decoded |> should.equal(payload)
}

pub fn encode_with_lz77_rep_matches_beat_new_distance_test() -> Nil {
  // Input that hits the same offset over and over (a 4-byte motif
  // repeated many times) is the textbook case for LZMA rep matches —
  // the encoder should reuse `rep0` instead of re-encoding the
  // distance and the resulting stream still has to round-trip.
  let props = lzma.Properties(lc: 3, lp: 0, pb: 2)
  let payload = repeat_bytes(<<"ABCD":utf8>>, 200)
  let encoded = lzma.encode_with_lz77(bytes: payload, props: props)
  let assert Ok(decoder) = lzma.new(encoded, props, 4096)
  let assert Ok(#(decoded, _state)) =
    lzma.decode_into(decoder, bit_array.byte_size(payload))
  decoded |> should.equal(payload)
  // 800 bytes that repeat a 4-byte motif must compress under 5 % —
  // the rep-match path is doing its job.
  case bit_array.byte_size(encoded) * 20 < bit_array.byte_size(payload) {
    True -> Nil
    False -> should.fail()
  }
}

pub fn encode_with_lz77_short_rep_beats_literal_test() -> Nil {
  // Payload designed to exercise the LZMA short-rep packet (a
  // length-1 rep0 with the byte at `pos - rep0 - 1` already
  // matching the current byte): a 3-byte motif "XYZ" repeated and
  // separated by a single filler letter the LZ77 finder won't pick
  // up.  After the first real match sets rep0 to 2 (distance 3
  // back), every later "X"/"Y"/"Z" that lines up with that distance
  // is emittable as a 4-prob-bit short-rep instead of a full
  // literal — so the encoded output must shrink below what the
  // literal-only encoder produces and still round-trip cleanly.
  let props = lzma.Properties(lc: 3, lp: 0, pb: 2)
  let payload =
    bit_array.concat([
      repeat_bytes(<<"XYZ":utf8>>, 4),
      <<"q":utf8>>,
      repeat_bytes(<<"XYZ":utf8>>, 4),
      <<"q":utf8>>,
      repeat_bytes(<<"XYZ":utf8>>, 4),
    ])
  let lz77 = lzma.encode_with_lz77(bytes: payload, props: props)
  let literal_only = lzma.encode_literal_only(bytes: payload, props: props)
  let assert Ok(decoder) = lzma.new(lz77, props, 1024)
  let assert Ok(#(decoded, _state)) =
    lzma.decode_into(decoder, bit_array.byte_size(payload))
  decoded |> should.equal(payload)
  case bit_array.byte_size(lz77) < bit_array.byte_size(literal_only) {
    True -> Nil
    False -> should.fail()
  }
}

pub fn encode_with_lz77_roundtrips_incompressible_test() -> Nil {
  // Bytes 0..255 cycling — no internal repetition until position 256,
  // which is also right at the 3-byte hash window edge.  LZ77 will
  // try matches but the resulting encoding still has to round-trip.
  let props = lzma.Properties(lc: 3, lp: 0, pb: 2)
  let payload = byte_cycle(0, 256, <<>>)
  let encoded = lzma.encode_with_lz77(bytes: payload, props: props)
  let assert Ok(decoder) = lzma.new(encoded, props, 4096)
  let assert Ok(#(decoded, _state)) =
    lzma.decode_into(decoder, bit_array.byte_size(payload))
  decoded |> should.equal(payload)
}

fn byte_cycle(n: Int, target: Int, acc: BitArray) -> BitArray {
  case n >= target {
    True -> acc
    False -> byte_cycle(n + 1, target, <<acc:bits, n>>)
  }
}

fn repeat_bytes(value: BitArray, times: Int) -> BitArray {
  case times {
    0 -> <<>>
    _ -> bit_array.concat([value, repeat_bytes(value, times - 1)])
  }
}
