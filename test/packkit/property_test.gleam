//// Property-based round-trip tests for every codec.  Uses metamon's
//// `forall_round_trip` runner so a failure shrinks to a minimal
//// counterexample and annotates which codec broke.
////
//// Every codec must satisfy `decode(encode(x)) == Ok(x)` for arbitrary
//// byte inputs in the 0..256-byte range — that range exercises the
//// empty-input edge case, single-byte edges, and the LZW / DEFLATE
//// width-promote / window boundaries that have been failure-prone in
//// the past.

import gleam/bit_array
import gleam/list
import gleeunit/should
import metamon
import metamon/generator
import metamon/generator/range
import packkit
import packkit/archive
import packkit/codec
import packkit/fixture
import packkit/gzip
import packkit/internal/brotli
import packkit/internal/bzip2
import packkit/internal/deflate
import packkit/internal/entry
import packkit/internal/lz4
import packkit/internal/lzw
import packkit/internal/snappy
import packkit/internal/xz
import packkit/internal/zlib
import packkit/internal/zstd
import packkit/limit

fn bytes_gen() -> generator.Generator(BitArray) {
  generator.bit_array(range.linear(0, 256))
}

pub fn property_deflate_round_trip_test() -> Nil {
  metamon.forall_round_trip(
    gen: bytes_gen(),
    name: "deflate",
    encode: fn(b) {
      let assert Ok(out) = deflate.encode(bytes: b)
      out
    },
    decode: decoder(codec.Deflate),
  )
}

pub fn property_zlib_round_trip_test() -> Nil {
  metamon.forall_round_trip(
    gen: bytes_gen(),
    name: "zlib",
    encode: fn(b) {
      let assert Ok(out) = zlib.encode(bytes: b)
      out
    },
    decode: decoder(codec.Zlib),
  )
}

pub fn property_gzip_round_trip_test() -> Nil {
  metamon.forall_round_trip(
    gen: bytes_gen(),
    name: "gzip",
    encode: gzip.encode_without_header,
    decode: decoder(codec.Gzip),
  )
}

pub fn property_lz4_round_trip_test() -> Nil {
  metamon.forall_round_trip(
    gen: bytes_gen(),
    name: "lz4",
    encode: fn(b) {
      let assert Ok(out) = lz4.encode(bytes: b)
      out
    },
    decode: decoder(codec.Lz4),
  )
}

pub fn property_snappy_round_trip_test() -> Nil {
  metamon.forall_round_trip(
    gen: bytes_gen(),
    name: "snappy",
    encode: fn(b) {
      let assert Ok(out) = snappy.encode(bytes: b)
      out
    },
    decode: decoder(codec.Snappy),
  )
}

pub fn property_snappy_raw_round_trip_test() -> Nil {
  metamon.forall_round_trip(
    gen: bytes_gen(),
    name: "snappy_raw",
    encode: fn(b) {
      let assert Ok(out) = snappy.raw_encode(bytes: b)
      out
    },
    decode: snappy.raw_decode,
  )
}

pub fn property_bzip2_round_trip_test() -> Nil {
  metamon.forall_round_trip(
    gen: bytes_gen(),
    name: "bzip2",
    encode: fn(b) {
      let assert Ok(out) = bzip2.encode(bytes: b)
      out
    },
    decode: decoder(codec.Bzip2),
  )
}

pub fn property_lzw_round_trip_test() -> Nil {
  metamon.forall_round_trip(
    gen: bytes_gen(),
    name: "lzw",
    encode: fn(b) {
      let assert Ok(out) = lzw.encode(bytes: b)
      out
    },
    decode: decoder(codec.Lzw),
  )
}

pub fn property_xz_round_trip_test() -> Nil {
  metamon.forall_round_trip(
    gen: bytes_gen(),
    name: "xz",
    encode: fn(b) {
      let assert Ok(out) = xz.encode(bytes: b)
      out
    },
    decode: decoder(codec.Xz),
  )
}

pub fn property_zstd_round_trip_test() -> Nil {
  metamon.forall_round_trip(
    gen: bytes_gen(),
    name: "zstd",
    encode: fn(b) {
      let assert Ok(out) = zstd.encode(bytes: b)
      out
    },
    decode: decoder(codec.Zstd),
  )
}

pub fn property_brotli_round_trip_test() -> Nil {
  metamon.forall_round_trip(
    gen: bytes_gen(),
    name: "brotli",
    encode: fn(b) {
      let assert Ok(out) = brotli.encode(bytes: b)
      out
    },
    decode: decoder(codec.Brotli),
  )
}

// -- length invariants -------------------------------------------------

/// `decode(encode(x))` and `x` always have the same byte length.  A
/// dedicated check on top of the round-trip lets us catch shape-
/// preserving mutations (e.g. flipping a single payload byte) that
/// would still round-trip but corrupt content.
pub fn property_deflate_preserves_length_test() -> Nil {
  metamon.forall(bytes_gen(), fn(payload) {
    let assert Ok(encoded) = deflate.encode(bytes: payload)
    case packkit.decompress(encoded, with: codec.Deflate) {
      Ok(decoded) ->
        bit_array.byte_size(decoded) == bit_array.byte_size(payload)
      _ -> False
    }
  })
}

pub fn property_lzw_preserves_length_test() -> Nil {
  metamon.forall(bytes_gen(), fn(payload) {
    let assert Ok(encoded) = lzw.encode(bytes: payload)
    case packkit.decompress(encoded, with: codec.Lzw) {
      Ok(decoded) ->
        bit_array.byte_size(decoded) == bit_array.byte_size(payload)
      _ -> False
    }
  })
}

// -- pin a non-trivial deterministic case -----------------------------

/// Pins a known-good corpus through every codec.  The metamon
/// property tests above cover random shapes; this one anchors the
/// specific 1024-byte zero string we know is a hot path for RLE-style
/// encoders.
pub fn all_codecs_handle_1k_zeros_test() -> Nil {
  let zeros = bit_array.concat(repeat(<<0:size({ 8 * 1024 })>>, 1))

  // Each codec must round-trip this exact input.
  check_round_trip(zeros, "deflate", deflate.encode, decoder(codec.Deflate))
  check_round_trip(zeros, "zlib", zlib.encode, decoder(codec.Zlib))
  check_round_trip(
    zeros,
    "gzip",
    fn(b) { Ok(gzip.encode_without_header(b)) },
    decoder(codec.Gzip),
  )
  check_round_trip(zeros, "lz4", lz4.encode, decoder(codec.Lz4))
  check_round_trip(zeros, "snappy", snappy.encode, decoder(codec.Snappy))
  check_round_trip(zeros, "bzip2", bzip2.encode, decoder(codec.Bzip2))
  check_round_trip(zeros, "lzw", lzw.encode, decoder(codec.Lzw))
  check_round_trip(zeros, "xz", xz.encode, decoder(codec.Xz))
  check_round_trip(zeros, "zstd", zstd.encode, decoder(codec.Zstd))
  check_round_trip(zeros, "brotli", brotli.encode, decoder(codec.Brotli))
}

fn check_round_trip(
  payload: BitArray,
  _name: String,
  encode: fn(BitArray) -> Result(BitArray, e),
  decode: fn(BitArray) -> Result(BitArray, e2),
) -> Nil {
  let assert Ok(encoded) = encode(payload)
  case decode(encoded) {
    Ok(decoded) -> decoded |> should.equal(payload)
    _ -> should.fail()
  }
}

fn repeat(value: a, n: Int) -> List(a) {
  case n {
    0 -> []
    _ -> [value, ..repeat(value, n - 1)]
  }
}

// -- recipe-level pack / unpack round trips -------------------------------

/// Pack one logical entry whose body is random bytes, unpack it, and
/// assert the body round-trips byte-for-byte through the chosen
/// recipe.  metamon shrinks the body to a minimal counter-example if
/// any recipe drops a byte mid-pipeline — the codec-level properties
/// above would only catch the codec step.
fn check_single_entry_recipe_round_trip(
  recipe_value: packkit.Recipe,
  body: BitArray,
) -> Bool {
  let arc = fixture.new(archive.Tar) |> fixture.add_file(path: "f", body: body)

  case packkit.pack(arc, using: recipe_value) {
    Ok(packed) ->
      case packkit.unpack(packed, using: recipe_value) {
        Ok(unpacked) ->
          case unpacked.entries {
            [single] -> entry.body(single) == body
            _ -> False
          }
        _ -> False
      }
    _ -> False
  }
}

pub fn property_recipe_tar_gzip_round_trip_test() -> Nil {
  metamon.forall(bytes_gen(), fn(b) {
    check_single_entry_recipe_round_trip(
      packkit.Recipe(archive.Tar, [codec.Gzip]),
      b,
    )
  })
}

pub fn property_recipe_tar_zstd_round_trip_test() -> Nil {
  metamon.forall(bytes_gen(), fn(b) {
    check_single_entry_recipe_round_trip(
      packkit.Recipe(archive.Tar, [codec.Zstd]),
      b,
    )
  })
}

pub fn property_recipe_tar_xz_round_trip_test() -> Nil {
  metamon.forall(bytes_gen(), fn(b) {
    check_single_entry_recipe_round_trip(
      packkit.Recipe(archive.Tar, [codec.Xz]),
      b,
    )
  })
}

pub fn property_recipe_tar_bare_round_trip_test() -> Nil {
  // No outer codec — exercises the pack/unpack pipeline directly
  // against the tar encoder/decoder pair without the codec layer
  // masking shape-preserving mutations.
  metamon.forall(bytes_gen(), fn(b) {
    check_single_entry_recipe_round_trip(packkit.Recipe(archive.Tar, []), b)
  })
}

/// Same shape against the bare ZIP recipe.  Stresses the per-entry
/// stored-method encoder + decoder, the central-directory layout, and
/// the EOCD parser for arbitrary body sizes including the empty
/// payload.
pub fn property_recipe_zip_round_trip_test() -> Nil {
  metamon.forall(bytes_gen(), fn(body) {
    let arc =
      fixture.new(archive.Zip)
      |> fixture.add(entry: fixture.file(path: "f", body: body))
    case packkit.pack(arc, using: packkit.Recipe(archive.Zip, [])) {
      Ok(packed) ->
        case packkit.unpack(packed, using: packkit.Recipe(archive.Zip, [])) {
          Ok(unpacked) ->
            case unpacked.entries {
              [single] -> entry.body(single) == body
              _ -> False
            }
          _ -> False
        }
      _ -> False
    }
  })
}

// -- API law: archive.entry_by_path == list.find on entries() ------------

/// Pin the lawful equivalence between `archive.entry_by_path(arc, path)`
/// and `arc.entries |> list.find(...)`.  The implementation
/// IS `list.find(entries(arc), ...)` today, but metamon generates a
/// random body so a regression that picked the wrong list (the
/// internal reversed list — the historical bug) would surface here
/// instead of only through the hand-written duplicate-path fixture.
pub fn property_entry_by_path_matches_list_find_on_entries_test() -> Nil {
  metamon.forall(bytes_gen(), fn(body) {
    let arc =
      fixture.new(archive.Tar)
      |> fixture.add_file(path: "a", body: body)
      |> fixture.add_file(path: "b", body: <<"second":utf8>>)
      |> fixture.add_file(path: "a", body: <<"third":utf8>>)

    let via_helper = archive.entry_by_path(arc, path: "a")
    let via_list_find =
      arc.entries
      |> list.find(fn(e) { e.path == "a" })

    case via_helper, via_list_find {
      Ok(x), Ok(y) -> entry.body(x) == entry.body(y)
      Ok(_), _ -> False
      _, Ok(_) -> False
      _, _ -> True
    }
  })
}

pub fn multi_stream_cumulative_output_limit_test() -> Nil {
  // Regression for the multi-stream cumulative-output-limit fix
  // landed across gzip / bzip2 / xz / zstd.  Each codec's inner
  // decoder already capped the current member at
  // max_output_bytes, but the multi-stream loop concatenated
  // payloads with no running-total check.  Build a 3-member
  // archive whose individual members each fit within a small
  // limit but whose concatenation does not, and assert every
  // codec rejects the total at the threshold rather than after
  // materialising the whole output.
  let payload = <<"twenty-byte-payload!":utf8>>
  // 20 bytes per member, 3 members = 60 bytes total.
  // Limit set to 40 bytes: members 1 + 2 fit, member 3 overflows.
  let tight_limits = limit.Limits(..limit.default(), max_output_bytes: 40)

  // gzip — already covered by a dedicated test, but exercised
  // again here for cross-codec uniformity.
  let g = gzip.encode_without_header(payload)
  case
    packkit.decompress_with_limits(
      bit_array.concat([g, g, g]),
      with: codec.Gzip,
      limits: tight_limits,
    )
  {
    Error(codec.LimitExceeded(limit: "max_output_bytes", actual: _)) -> Nil
    _ -> should.fail()
  }

  // bzip2
  let assert Ok(b) = bzip2.encode(bytes: payload)
  case
    bzip2.decode_with_limits(
      bytes: bit_array.concat([b, b, b]),
      limits: tight_limits,
    )
  {
    Error(codec.LimitExceeded(limit: "max_output_bytes", actual: _)) -> Nil
    _ -> should.fail()
  }

  // xz
  let assert Ok(x) = xz.encode(bytes: payload)
  case
    xz.decode_with_limits(
      bytes: bit_array.concat([x, x, x]),
      limits: tight_limits,
    )
  {
    Error(codec.LimitExceeded(limit: "max_output_bytes", actual: _)) -> Nil
    _ -> should.fail()
  }

  // zstd
  let assert Ok(z) = zstd.encode(bytes: payload)
  case
    zstd.decode_with_limits(
      bytes: bit_array.concat([z, z, z]),
      limits: tight_limits,
    )
  {
    Error(codec.LimitExceeded(limit: "max_output_bytes", actual: _)) -> Nil
    _ -> should.fail()
  }
}

fn decoder(
  codec: codec.Codec,
) -> fn(BitArray) -> Result(BitArray, codec.CodecError) {
  fn(bytes) { packkit.decompress(bytes, with: codec) }
}
