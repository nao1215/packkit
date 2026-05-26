//// RFC 1952 gzip codec.
////
//// gzip wraps a DEFLATE stream in a member header that may carry an
//// original filename, free-text comment, and modification timestamp.
//// A trailing CRC-32 and ISIZE pair lets readers verify the decoded
//// payload.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import packkit/checksum
import packkit/codec as codecs
import packkit/deflate
import packkit/error
import packkit/limit

const magic_byte_1: Int = 0x1F

const magic_byte_2: Int = 0x8B

const cm_deflate: Int = 8

const ftext_flag: Int = 0x01

const fhcrc_flag: Int = 0x02

const fextra_flag: Int = 0x04

const fname_flag: Int = 0x08

const fcomment_flag: Int = 0x10

const os_unknown: Int = 0xFF

/// Gzip header metadata.
pub opaque type Header {
  Header(
    name: Option(String),
    comment: Option(String),
    modified_at_unix: Option(Int),
    extra: List(Subfield),
  )
}

/// One FEXTRA subfield (RFC 1952 §2.3.1.1).  `id_1` and `id_2` are
/// the two ASCII bytes that name the subfield (per the spec they
/// SHOULD be a recognised registry entry but the format does not
/// enforce that); `data` is the subfield body (up to 65 535 bytes).
///
/// Each subfield is encoded as `<id_1, id_2, LEN(LE 16), data>`,
/// and the full FEXTRA region begins with the 16-bit little-endian
/// total length of all subfields concatenated.
pub type Subfield {
  Subfield(id_1: Int, id_2: Int, data: BitArray)
}

/// Incremental decoder state.  Buffers the input chunks and runs the
/// one-shot decoder at `finish` time.  Streaming is presented as
/// "feed-and-finalize" rather than "produce a partial output per
/// push" because the underlying DEFLATE decoder is eager — but the
/// API still lets callers wire incremental pipelines from sources
/// that hand them data in chunks.  See `packkit/stream` for the
/// codec-neutral version of this surface.
///
/// `buffered_bytes` is tracked so `push` can enforce `max_input_bytes`
/// incrementally: a hostile or buggy producer that streams ever-larger
/// chunks can no longer overrun the limit silently by accumulating in
/// the decoder before `finish` runs.
pub opaque type Decoder {
  Decoder(
    reversed_chunks: List(BitArray),
    buffered_bytes: Int,
    limits: limit.Limits,
  )
}

/// Gzip codec smart constructor.
pub fn codec() -> codecs.Codec {
  codecs.gzip()
}

/// Default gzip header with no optional fields populated.
pub fn default_header() -> Header {
  Header(name: None, comment: None, modified_at_unix: None, extra: [])
}

/// Attach an optional filename.  Panics if `name` contains the NUL
/// byte gzip uses as the FNAME terminator — see [with_name_checked]
/// when the value comes from untrusted input.
///
/// The unchecked variant guarantees that the value stored in the
/// header is exactly what the caller passed (lawful round-trip via
/// `name(with_name(h, x)) == Some(x)`).  Earlier revisions silently
/// stripped NULs to "be helpful"; that broke the round-trip law and
/// is now a panic, matching the other unchecked setters in this
/// module ([with_modified_at] / [with_extra]) and across the package
/// ([packkit/entry.with_mode] etc.).
pub fn with_name(header: Header, name name: String) -> Header {
  case with_name_checked(header, name: name) {
    Ok(h) -> h
    Error(_) ->
      panic as "packkit/gzip.with_name: name must not contain NUL (0x00)"
  }
}

/// Attach an optional comment.  Panics if `comment` contains the NUL
/// byte gzip uses as the FCOMMENT terminator — see
/// [with_comment_checked] when the value comes from untrusted input.
///
/// Like [with_name], the stored value is exactly what the caller
/// passed; earlier revisions silently stripped NULs.
pub fn with_comment(header: Header, comment comment: String) -> Header {
  case with_comment_checked(header, comment: comment) {
    Ok(h) -> h
    Error(_) ->
      panic as "packkit/gzip.with_comment: comment must not contain NUL (0x00)"
  }
}

/// Why a checked header constructor rejected an argument.
pub type HeaderError {
  HeaderNameContainsNul
  HeaderCommentContainsNul
  /// `modified_at_unix` must fit in gzip's 32-bit MTIME field
  /// (`0..2^32-1`).  Surfaced here rather than silently wrapping at
  /// `encode` time.
  HeaderModifiedAtOutOfRange(value: Int)
  /// A single FEXTRA subfield must fit gzip's 16-bit LEN field; the
  /// entire FEXTRA region must also fit gzip's 16-bit XLEN field.
  /// Either overflow surfaces here at `with_extra_checked` time
  /// rather than silently truncating the data inside `encode`.
  HeaderExtraSubfieldTooLong(actual: Int)
  HeaderExtraTotalTooLong(actual: Int)
  /// FEXTRA subfield IDs are two bytes; values outside `0..255`
  /// cannot be packed into a single byte each.
  HeaderExtraSubfieldIdOutOfRange(id_1: Int, id_2: Int)
}

/// Attach an optional filename after validating that it does not
/// contain the NUL byte gzip uses as the FNAME terminator.  Use this
/// when the value comes from untrusted input that must round-trip.
pub fn with_name_checked(
  header: Header,
  name name: String,
) -> Result(Header, HeaderError) {
  use <- bool.guard(
    when: string.contains(name, "\u{0000}"),
    return: Error(HeaderNameContainsNul),
  )
  Ok(Header(..header, name: Some(name)))
}

/// Attach an optional comment after validating that it does not
/// contain the NUL byte gzip uses as the FCOMMENT terminator.
pub fn with_comment_checked(
  header: Header,
  comment comment: String,
) -> Result(Header, HeaderError) {
  use <- bool.guard(
    when: string.contains(comment, "\u{0000}"),
    return: Error(HeaderCommentContainsNul),
  )
  Ok(Header(..header, comment: Some(comment)))
}

/// Attach an optional Unix mtime.  Out-of-range values panic at
/// construction time so a `Header` value cannot quietly carry a
/// timestamp gzip's 32-bit MTIME field cannot represent.  Use
/// [with_modified_at_checked] when the input is untrusted.
pub fn with_modified_at(
  header: Header,
  unix_seconds unix_seconds: Int,
) -> Header {
  case with_modified_at_checked(header, unix_seconds: unix_seconds) {
    Ok(h) -> h
    Error(_) ->
      panic as "packkit/gzip.with_modified_at: unix_seconds must be in the inclusive range 0..0xFFFFFFFF"
  }
}

/// Attach an optional Unix mtime after validating it fits gzip's
/// 32-bit MTIME field.
pub fn with_modified_at_checked(
  header: Header,
  unix_seconds unix_seconds: Int,
) -> Result(Header, HeaderError) {
  use <- bool.guard(
    when: unix_seconds < 0 || unix_seconds > 0xFFFFFFFF,
    return: Error(HeaderModifiedAtOutOfRange(value: unix_seconds)),
  )
  Ok(Header(..header, modified_at_unix: Some(unix_seconds)))
}

/// Read the optional filename field.
pub fn name(header: Header) -> Option(String) {
  header.name
}

/// Read the optional comment field.
pub fn comment(header: Header) -> Option(String) {
  header.comment
}

/// Read the optional mtime field.
pub fn modified_at_unix(header: Header) -> Option(Int) {
  header.modified_at_unix
}

/// Read the FEXTRA subfields.  Empty when the gzip header carries
/// no FEXTRA region.
pub fn extra(header: Header) -> List(Subfield) {
  header.extra
}

/// Attach a list of FEXTRA subfields.  Out-of-range IDs or
/// overlong bodies panic; use [with_extra_checked] when the caller
/// has not pre-validated the values.
pub fn with_extra(header: Header, subfields subfields: List(Subfield)) -> Header {
  case with_extra_checked(header, subfields: subfields) {
    Ok(h) -> h
    Error(HeaderExtraSubfieldIdOutOfRange(_, _)) ->
      panic as "packkit/gzip.with_extra: subfield id bytes must each be in 0..255"
    Error(HeaderExtraSubfieldTooLong(_)) ->
      panic as "packkit/gzip.with_extra: each subfield body must be at most 65535 bytes"
    Error(HeaderExtraTotalTooLong(_)) ->
      panic as "packkit/gzip.with_extra: total FEXTRA region must be at most 65535 bytes"
    Error(_) -> panic as "packkit/gzip.with_extra: unexpected validation error"
  }
}

/// Attach a list of FEXTRA subfields after validating that every
/// subfield ID byte fits the 8-bit slot, every subfield body fits
/// gzip's 16-bit LEN, and the catenated total fits the 16-bit
/// XLEN.  Returns a typed `HeaderError` on any of those overflows.
pub fn with_extra_checked(
  header: Header,
  subfields subfields: List(Subfield),
) -> Result(Header, HeaderError) {
  use _ <- result.try(validate_extra_subfield_ids(subfields))
  use total <- result.try(measure_extra_subfields(subfields, 0))
  use <- bool.guard(
    when: total > 0xFFFF,
    return: Error(HeaderExtraTotalTooLong(actual: total)),
  )
  Ok(Header(..header, extra: subfields))
}

fn validate_extra_subfield_ids(
  subfields: List(Subfield),
) -> Result(Nil, HeaderError) {
  case subfields {
    [] -> Ok(Nil)
    [Subfield(id_1: id_1, id_2: id_2, data: _), ..rest] ->
      case id_1 < 0 || id_1 > 0xFF || id_2 < 0 || id_2 > 0xFF {
        True -> Error(HeaderExtraSubfieldIdOutOfRange(id_1: id_1, id_2: id_2))
        False -> validate_extra_subfield_ids(rest)
      }
  }
}

fn measure_extra_subfields(
  subfields: List(Subfield),
  acc: Int,
) -> Result(Int, HeaderError) {
  case subfields {
    [] -> Ok(acc)
    [Subfield(id_1: _, id_2: _, data: data), ..rest] -> {
      let len = bit_array.byte_size(data)
      case len > 0xFFFF {
        True -> Error(HeaderExtraSubfieldTooLong(actual: len))
        False -> measure_extra_subfields(rest, acc + 4 + len)
      }
    }
  }
}

/// Encode `bytes` as a gzip stream using the default header (no
/// FNAME / FCOMMENT / FEXTRA / mtime).  Use this when you just want
/// "compress these bytes" — the symmetric counterpart of
/// `decode_payload`, mirroring every other codec's `encode/1` shape.
/// Use [encode_with_header] when you need to attach a filename,
/// comment, or mtime to the stream.
pub fn encode(bytes bytes: BitArray) -> Result(BitArray, error.CodecError) {
  encode_with_header(bytes: bytes, header: default_header())
}

/// Encode `bytes` as a gzip stream using `header`.  The DEFLATE body
/// uses the dynamic-Huffman encoder, which on typical text and
/// structured-data payloads shrinks ~10–30 % more than the fixed-
/// Huffman variant; for pathologically skewed inputs the encoder
/// transparently falls back to fixed Huffman inside
/// `deflate.encode_dynamic` so the stream is always a valid
/// RFC 1951 BTYPE=01 or BTYPE=10 block.
pub fn encode_with_header(
  bytes bytes: BitArray,
  header header: Header,
) -> Result(BitArray, error.CodecError) {
  use deflated <- result.try(deflate.encode_dynamic(bytes: bytes))

  let mtime = case header.modified_at_unix {
    Some(value) -> value
    None -> 0
  }

  let flag_extra = case header.extra {
    [] -> 0
    _ -> fextra_flag
  }
  let flag_name = case header.name {
    Some(_) -> fname_flag
    None -> 0
  }
  let flag_comment = case header.comment {
    Some(_) -> fcomment_flag
    None -> 0
  }
  let flg = int.bitwise_or(int.bitwise_or(flag_extra, flag_name), flag_comment)

  let header_bytes = <<
    magic_byte_1,
    magic_byte_2,
    cm_deflate,
    flg,
    mtime:size(32)-little,
    0,
    os_unknown,
  >>

  let extra_block = encode_extra_block(header.extra)

  let name_block = case header.name {
    Some(value) -> bit_array.concat([bit_array.from_string(value), <<0>>])
    None -> <<>>
  }

  let comment_block = case header.comment {
    Some(value) -> bit_array.concat([bit_array.from_string(value), <<0>>])
    None -> <<>>
  }

  let trailer = trailer_bytes(bytes)

  Ok(
    bit_array.concat([
      header_bytes,
      extra_block,
      name_block,
      comment_block,
      deflated,
      trailer,
    ]),
  )
}

fn encode_extra_block(subfields: List(Subfield)) -> BitArray {
  case subfields {
    [] -> <<>>
    _ -> {
      let body = encode_extra_subfields(subfields, <<>>)
      let xlen = bit_array.byte_size(body)
      bit_array.concat([<<xlen:size(16)-little>>, body])
    }
  }
}

fn encode_extra_subfields(subfields: List(Subfield), acc: BitArray) -> BitArray {
  case subfields {
    [] -> acc
    [Subfield(id_1: id_1, id_2: id_2, data: data), ..rest] -> {
      let len = bit_array.byte_size(data)
      let chunk = bit_array.concat([<<id_1, id_2, len:size(16)-little>>, data])
      encode_extra_subfields(rest, bit_array.concat([acc, chunk]))
    }
  }
}

fn trailer_bytes(plain: BitArray) -> BitArray {
  let crc = checksum.crc32(plain)
  let isize = int.bitwise_and(bit_array.byte_size(plain), 0xFFFFFFFF)
  <<crc:size(32)-little, isize:size(32)-little>>
}

/// Decoded gzip stream.
pub type Decoded {
  Decoded(header: Header, payload: BitArray)
}

/// Decode a gzip byte stream using default limits and return the
/// rich [Decoded] record (header + payload).
///
/// `decode` is asymmetric with [encode]: `encode` takes payload bytes
/// and emits a stream, while `decode` returns both the payload and the
/// header.  The asymmetry is intentional — gzip is the only codec in
/// the package that carries meaningful per-stream metadata (filename,
/// comment, mtime), and surfacing it on the decode side is what makes
/// `decode |> .header` useful.  When you only care about the payload
/// and want the shape every other codec uses (`BitArray ->
/// Result(BitArray, _)`), use [decode_payload].
pub fn decode(bytes bytes: BitArray) -> Result(Decoded, error.CodecError) {
  decode_with_limits(bytes: bytes, limits: limit.default())
}

/// Decode a gzip byte stream and return only the payload bytes.
/// Parallels every other codec's `decode/1`, which returns
/// `Result(BitArray, _)` — use this when you don't need the gzip
/// header (mtime / filename / comment).
///
/// Law: `decode_payload(b) == decode(b) |> result.map(fn(d) { d.payload })`.
pub fn decode_payload(
  bytes bytes: BitArray,
) -> Result(BitArray, error.CodecError) {
  case decode(bytes: bytes) {
    Ok(decoded) -> Ok(decoded.payload)
    Error(e) -> Error(e)
  }
}

/// Like [decode_payload] but accepts an explicit `Limits` value.
pub fn decode_payload_with_limits(
  bytes bytes: BitArray,
  limits limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  case decode_with_limits(bytes: bytes, limits: limits) {
    Ok(decoded) -> Ok(decoded.payload)
    Error(e) -> Error(e)
  }
}

/// Decode a gzip byte stream using explicit limits.
///
/// Handles multi-member streams (RFC 1952 §2.2 — concatenated gzip
/// files such as those produced by `cat a.gz b.gz`).  The returned
/// `Decoded` carries the header from the FIRST member and the
/// concatenated payload of every member that decoded successfully;
/// no other gzip API exposes per-member headers yet.
pub fn decode_with_limits(
  bytes bytes: BitArray,
  limits limits: limit.Limits,
) -> Result(Decoded, error.CodecError) {
  use <- bool.guard(
    when: bit_array.byte_size(bytes) > limit.max_input_bytes(limits),
    return: Error(error.CodecLimitExceeded(
      limit: "max_input_bytes",
      actual: bit_array.byte_size(bytes),
    )),
  )

  decode_first_member_and_continue(bytes, limits)
}

fn decode_first_member_and_continue(
  bytes: BitArray,
  limits: limit.Limits,
) -> Result(Decoded, error.CodecError) {
  use #(decoded, rest) <- result.try(decode_one_member(bytes, limits))
  case bit_array.byte_size(rest) {
    0 -> Ok(decoded)
    _ -> {
      let initial_size = bit_array.byte_size(decoded.payload)
      use additional <- result.try(decode_remaining_members(
        rest,
        <<>>,
        initial_size,
        limits,
      ))
      Ok(
        Decoded(
          ..decoded,
          payload: bit_array.concat([decoded.payload, additional]),
        ),
      )
    }
  }
}

fn decode_remaining_members(
  bytes: BitArray,
  acc: BitArray,
  accumulated_size: Int,
  limits: limit.Limits,
) -> Result(BitArray, error.CodecError) {
  case bit_array.byte_size(bytes) {
    0 -> Ok(acc)
    _ -> {
      use #(decoded, rest) <- result.try(decode_one_member(bytes, limits))
      let next_size = accumulated_size + bit_array.byte_size(decoded.payload)
      case next_size > limit.max_output_bytes(limits) {
        True ->
          Error(error.CodecLimitExceeded(
            limit: "max_output_bytes",
            actual: next_size,
          ))
        False ->
          decode_remaining_members(
            rest,
            bit_array.concat([acc, decoded.payload]),
            next_size,
            limits,
          )
      }
    }
  }
}

fn decode_one_member(
  bytes: BitArray,
  limits: limit.Limits,
) -> Result(#(Decoded, BitArray), error.CodecError) {
  case bytes {
    <<m1, m2, cm, flg, mtime:size(32)-little, _xfl, _os, rest:bytes>> -> {
      use <- bool.guard(
        when: m1 != magic_byte_1 || m2 != magic_byte_2,
        return: Error(error.CodecInvalidData(message: "gzip magic mismatch")),
      )
      use <- bool.guard(
        when: cm != cm_deflate,
        return: Error(error.CodecInvalidData(
          message: "gzip compression method is not deflate",
        )),
      )
      // RFC 1952 §2.3.1: MTIME=0 means "no time stamp available".
      let initial = case mtime {
        0 -> default_header()
        n -> Header(..default_header(), modified_at_unix: Some(n))
      }
      decode_header_and_payload(rest, flg, initial, limits)
    }
    _ -> Error(error.CodecInvalidData(message: "gzip header truncated"))
  }
}

fn decode_header_and_payload(
  bytes: BitArray,
  flg: Int,
  acc: Header,
  limits: limit.Limits,
) -> Result(#(Decoded, BitArray), error.CodecError) {
  use #(bytes, extra_value) <- result.try(maybe_read_extra(bytes, flg))
  use #(bytes, name_value) <- result.try(maybe_read_string(
    bytes,
    flg,
    fname_flag,
  ))
  use #(bytes, comment_value) <- result.try(maybe_read_string(
    bytes,
    flg,
    fcomment_flag,
  ))
  use bytes <- result.try(maybe_skip_header_crc(bytes, flg))

  let header =
    acc
    |> apply_optional_name(name_value)
    |> apply_optional_comment(comment_value)
    |> apply_extra(extra_value)

  let _ = int.bitwise_and(flg, ftext_flag)

  // Decode the deflate stream and learn exactly where it ends so the
  // 8-byte CRC/ISIZE trailer can be read at the right offset and the
  // remainder (if any) can be handed off to the next gzip member.
  use #(plain, after_deflate) <- result.try(deflate.decode_with_remainder(
    bytes: bytes,
    limits: limits,
  ))

  case after_deflate {
    <<expected_crc:size(32)-little, expected_isize:size(32)-little, rest:bytes>> -> {
      use <- bool.guard(
        when: checksum.crc32(plain) != expected_crc,
        return: Error(error.CodecInvalidData(message: "gzip CRC-32 mismatch")),
      )

      let isize = int.bitwise_and(bit_array.byte_size(plain), 0xFFFFFFFF)
      use <- bool.guard(
        when: isize != expected_isize,
        return: Error(error.CodecInvalidData(message: "gzip ISIZE mismatch")),
      )

      Ok(#(Decoded(header: header, payload: plain), rest))
    }
    _ -> Error(error.CodecInvalidData(message: "gzip trailer truncated"))
  }
}

fn apply_optional_name(header: Header, value: Option(String)) -> Header {
  case value {
    Some(v) -> with_name(header, name: v)
    None -> header
  }
}

fn apply_optional_comment(header: Header, value: Option(String)) -> Header {
  case value {
    Some(v) -> with_comment(header, comment: v)
    None -> header
  }
}

fn apply_extra(header: Header, subfields: List(Subfield)) -> Header {
  case subfields {
    [] -> header
    _ -> Header(..header, extra: subfields)
  }
}

fn maybe_read_extra(
  bytes: BitArray,
  flg: Int,
) -> Result(#(BitArray, List(Subfield)), error.CodecError) {
  case int.bitwise_and(flg, fextra_flag) {
    0 -> Ok(#(bytes, []))
    _ ->
      case bytes {
        <<xlen:size(16)-little, rest:bytes>> ->
          case bit_array.byte_size(rest) < xlen {
            True ->
              Error(error.CodecInvalidData(
                message: "gzip extra field truncated",
              ))
            False -> {
              let assert Ok(extra_bytes) = bit_array.slice(rest, 0, xlen)
              let assert Ok(after) =
                bit_array.slice(rest, xlen, bit_array.byte_size(rest) - xlen)
              use subfields <- result.try(
                parse_extra_subfields(extra_bytes, []),
              )
              Ok(#(after, list.reverse(subfields)))
            }
          }
        _ ->
          Error(error.CodecInvalidData(message: "gzip extra header truncated"))
      }
  }
}

fn parse_extra_subfields(
  bytes: BitArray,
  acc: List(Subfield),
) -> Result(List(Subfield), error.CodecError) {
  case bit_array.byte_size(bytes) {
    0 -> Ok(acc)
    _ ->
      case bytes {
        <<id_1, id_2, len:size(16)-little, rest:bytes>> ->
          case bit_array.byte_size(rest) < len {
            True ->
              Error(error.CodecInvalidData(
                message: "gzip extra subfield body truncated",
              ))
            False -> {
              let assert Ok(data) = bit_array.slice(rest, 0, len)
              let assert Ok(remaining) =
                bit_array.slice(rest, len, bit_array.byte_size(rest) - len)
              parse_extra_subfields(remaining, [
                Subfield(id_1: id_1, id_2: id_2, data: data),
                ..acc
              ])
            }
          }
        _ ->
          Error(error.CodecInvalidData(
            message: "gzip extra subfield header truncated",
          ))
      }
  }
}

fn maybe_read_string(
  bytes: BitArray,
  flg: Int,
  mask: Int,
) -> Result(#(BitArray, Option(String)), error.CodecError) {
  case int.bitwise_and(flg, mask) {
    0 -> Ok(#(bytes, None))
    _ ->
      case split_at_nul(bytes, 0) {
        Ok(#(string_bits, after)) ->
          case bit_array.to_string(string_bits) {
            Ok(value) -> Ok(#(after, Some(value)))
            Error(_) ->
              Error(error.CodecInvalidData(
                message: "gzip header string is not UTF-8",
              ))
          }
        Error(err) -> Error(err)
      }
  }
}

fn split_at_nul(
  bytes: BitArray,
  offset: Int,
) -> Result(#(BitArray, BitArray), error.CodecError) {
  case bit_array.slice(bytes, offset, 1) {
    Ok(<<0>>) -> {
      let assert Ok(prefix) = bit_array.slice(bytes, 0, offset)
      let total = bit_array.byte_size(bytes)
      let assert Ok(rest) =
        bit_array.slice(bytes, offset + 1, total - offset - 1)
      Ok(#(prefix, rest))
    }
    Ok(_) -> split_at_nul(bytes, offset + 1)
    Error(_) ->
      Error(error.CodecInvalidData(message: "gzip header string missing NUL"))
  }
}

fn maybe_skip_header_crc(
  bytes: BitArray,
  flg: Int,
) -> Result(BitArray, error.CodecError) {
  case int.bitwise_and(flg, fhcrc_flag) {
    0 -> Ok(bytes)
    _ ->
      case bit_array.slice(bytes, 2, bit_array.byte_size(bytes) - 2) {
        Ok(rest) -> Ok(rest)
        Error(_) ->
          Error(error.CodecInvalidData(message: "gzip header CRC missing"))
      }
  }
}

/// Create a new incremental decoder state using the default limits.
pub fn new_decoder() -> Decoder {
  Decoder(reversed_chunks: [], buffered_bytes: 0, limits: limit.default())
}

/// Create a new incremental decoder state with explicit limits.
pub fn new_decoder_with_limits(limits: limit.Limits) -> Decoder {
  Decoder(reversed_chunks: [], buffered_bytes: 0, limits: limits)
}

/// Append a chunk of input bytes to the decoder, enforcing
/// `max_input_bytes` incrementally.  Returns the updated decoder; no
/// output is produced until [finish] runs (the underlying DEFLATE
/// decoder is eager).
///
/// The shape mirrors [packkit/stream] so callers don't have to remember
/// which streaming module returns which tuple — previously this push
/// returned `(Decoder, List(BitArray))` and the equivalent
/// `stream.push` returned a bare `Decoder`.
pub fn push(
  decoder: Decoder,
  chunk: BitArray,
) -> Result(Decoder, error.CodecError) {
  let chunk_size = bit_array.byte_size(chunk)
  let new_total = decoder.buffered_bytes + chunk_size
  case new_total > limit.max_input_bytes(decoder.limits) {
    True ->
      Error(error.CodecLimitExceeded(
        limit: "max_input_bytes",
        actual: new_total,
      ))
    False ->
      Ok(
        Decoder(
          ..decoder,
          reversed_chunks: [chunk, ..decoder.reversed_chunks],
          buffered_bytes: new_total,
        ),
      )
  }
}

/// Finalize the decoder and return the full decoded payload.
///
/// Returns a bare `BitArray` (not `List(BitArray)`) so the gzip
/// streaming surface matches `packkit/stream` exactly.
pub fn finish(decoder: Decoder) -> Result(BitArray, error.CodecError) {
  // `bit_array.concat` over the forward-order list is O(total_bytes);
  // the previous fold called `concat([head, acc])` per chunk, which
  // copied `acc` each iteration and produced O(N * B * N) behaviour.
  let bytes = bit_array.concat(list.reverse(decoder.reversed_chunks))
  case decode_with_limits(bytes: bytes, limits: decoder.limits) {
    Ok(decoded) -> Ok(decoded.payload)
    Error(e) -> Error(e)
  }
}
