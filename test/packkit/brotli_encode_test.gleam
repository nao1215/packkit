//// Brotli encoder round-trip tests.  Each test encodes a known
//// payload with `brotli.encode`, decodes it back with `brotli.decode`,
//// and asserts the round-trip matches.

import gleam/bit_array
import gleeunit/should
import packkit/brotli

pub fn empty_round_trips_test() -> Nil {
  let payload = <<>>
  let assert Ok(encoded) = brotli.encode(bytes: payload)
  let assert Ok(decoded) = brotli.decode(bytes: encoded)
  decoded |> should.equal(payload)
}

pub fn short_text_round_trips_test() -> Nil {
  let payload = <<"hello, brotli!":utf8>>
  let assert Ok(encoded) = brotli.encode(bytes: payload)
  let assert Ok(decoded) = brotli.decode(bytes: encoded)
  decoded |> should.equal(payload)
}

pub fn repeated_text_round_trips_test() -> Nil {
  let payload = repeat_bytes(<<"abc":utf8>>, 100)
  let assert Ok(encoded) = brotli.encode(bytes: payload)
  let assert Ok(decoded) = brotli.decode(bytes: encoded)
  decoded |> should.equal(payload)
}

pub fn full_byte_range_round_trips_test() -> Nil {
  let payload = byte_range_cycle(0, 256, <<>>)
  let assert Ok(encoded) = brotli.encode(bytes: payload)
  let assert Ok(decoded) = brotli.decode(bytes: encoded)
  decoded |> should.equal(payload)
}

fn repeat_bytes(value: BitArray, times: Int) -> BitArray {
  case times {
    0 -> <<>>
    _ -> bit_array.concat([value, repeat_bytes(value, times - 1)])
  }
}

fn byte_range_cycle(n: Int, target: Int, acc: BitArray) -> BitArray {
  case n >= target {
    True -> acc
    False -> byte_range_cycle(n + 1, target, <<acc:bits, n>>)
  }
}
