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
  )
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
  Header(name: None, comment: None, modified_at_unix: None)
}

/// Attach an optional filename.
///
/// **Warning:** gzip terminates the FNAME field with a NUL byte, so a
/// name containing `\0` cannot round-trip — readers will truncate at
/// the first NUL.  Prefer [with_name_checked] when the value comes
/// from untrusted input; this unchecked counterpart silently strips
/// embedded NULs so an already-validated string is still safe to pass.
pub fn with_name(header: Header, name name: String) -> Header {
  Header(..header, name: Some(string.replace(name, "\u{0000}", "")))
}

/// Attach an optional comment.  See [with_name] for the NUL contract;
/// embedded NULs are silently stripped.  Use [with_comment_checked]
/// when callers may pass untrusted input that needs to round-trip
/// faithfully.
pub fn with_comment(header: Header, comment comment: String) -> Header {
  Header(..header, comment: Some(string.replace(comment, "\u{0000}", "")))
}

/// Why a checked header constructor rejected an argument.
pub type HeaderError {
  HeaderNameContainsNul
  HeaderCommentContainsNul
  /// `modified_at_unix` must fit in gzip's 32-bit MTIME field
  /// (`0..2^32-1`).  Surfaced here rather than silently wrapping at
  /// `encode` time.
  HeaderModifiedAtOutOfRange(value: Int)
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

/// Encode `bytes` as a gzip stream using `header`.
pub fn encode(
  bytes bytes: BitArray,
  header header: Header,
) -> Result(BitArray, error.CodecError) {
  use deflated <- result.try(deflate.encode(bytes: bytes))

  let mtime = case header.modified_at_unix {
    Some(value) -> value
    None -> 0
  }

  let flag_name = case header.name {
    Some(_) -> fname_flag
    None -> 0
  }
  let flag_comment = case header.comment {
    Some(_) -> fcomment_flag
    None -> 0
  }
  let flg = int.bitwise_or(flag_name, flag_comment)

  let header_bytes = <<
    magic_byte_1,
    magic_byte_2,
    cm_deflate,
    flg,
    mtime:size(32)-little,
    0,
    os_unknown,
  >>

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
      name_block,
      comment_block,
      deflated,
      trailer,
    ]),
  )
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

/// Decode a gzip byte stream using default limits.
pub fn decode(bytes bytes: BitArray) -> Result(Decoded, error.CodecError) {
  decode_with_limits(bytes: bytes, limits: limit.default())
}

/// Decode a gzip byte stream and return only the payload bytes.
/// Parallels every other codec's `decode/1`, which returns
/// `Result(BitArray, _)` — use this when you don't need the gzip
/// header (mtime / filename / comment).
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
  use #(bytes, _) <- result.try(maybe_skip_extra(bytes, flg))
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

fn maybe_skip_extra(
  bytes: BitArray,
  flg: Int,
) -> Result(#(BitArray, Nil), error.CodecError) {
  case int.bitwise_and(flg, fextra_flag) {
    0 -> Ok(#(bytes, Nil))
    _ ->
      case bytes {
        <<xlen:size(16)-little, rest:bytes>> ->
          case bit_array.byte_size(rest) < xlen {
            True ->
              Error(error.CodecInvalidData(
                message: "gzip extra field truncated",
              ))
            False -> {
              let assert Ok(after) =
                bit_array.slice(rest, xlen, bit_array.byte_size(rest) - xlen)
              Ok(#(after, Nil))
            }
          }
        _ ->
          Error(error.CodecInvalidData(message: "gzip extra header truncated"))
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
