//// RFC 1952 gzip codec.
////
//// gzip wraps a DEFLATE stream in a member header that may carry an
//// original filename, free-text comment, and modification timestamp.
//// A trailing CRC-32 and ISIZE pair lets readers verify the decoded
//// payload.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
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

/// Placeholder incremental decoder state (kept for API stability while
/// streaming support is under construction).
pub opaque type Decoder {
  Decoder(header: Header, reversed_chunks: List(BitArray))
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
pub fn with_name(header: Header, name name: String) -> Header {
  Header(..header, name: Some(name))
}

/// Attach an optional comment.
pub fn with_comment(header: Header, comment comment: String) -> Header {
  Header(..header, comment: Some(comment))
}

/// Attach an optional Unix mtime.
pub fn with_modified_at(
  header: Header,
  unix_seconds unix_seconds: Int,
) -> Header {
  Header(..header, modified_at_unix: Some(unix_seconds))
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
pub fn decode_with_limits(
  bytes bytes: BitArray,
  limits limits: limit.Limits,
) -> Result(Decoded, error.CodecError) {
  use <- bool.guard(
    when: bit_array.byte_size(bytes) > limit.max_input_bytes(limits),
    return: Error(error.CodecLimitExceeded(
      limit: "max_input_bytes",
      value: bit_array.byte_size(bytes),
    )),
  )

  case bytes {
    <<m1, m2, cm, flg, _mtime:size(32)-little, _xfl, _os, rest:bytes>> -> {
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
      decode_header(rest, flg, default_header(), limits)
    }
    _ -> Error(error.CodecInvalidData(message: "gzip header truncated"))
  }
}

fn decode_header(
  bytes: BitArray,
  flg: Int,
  acc: Header,
  limits: limit.Limits,
) -> Result(Decoded, error.CodecError) {
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

  let total_size = bit_array.byte_size(bytes)
  use <- bool.guard(
    when: total_size < 8,
    return: Error(error.CodecInvalidData(message: "gzip trailer truncated")),
  )

  let deflate_size = total_size - 8
  let assert Ok(deflate_bits) = bit_array.slice(bytes, 0, deflate_size)
  let assert Ok(trailer_bits) = bit_array.slice(bytes, deflate_size, 8)
  let assert <<expected_crc:size(32)-little, expected_isize:size(32)-little>> =
    trailer_bits

  use plain <- result.try(deflate.decode_with_limits(
    bytes: deflate_bits,
    limits: limits,
  ))

  use <- bool.guard(
    when: checksum.crc32(plain) != expected_crc,
    return: Error(error.CodecInvalidData(message: "gzip CRC-32 mismatch")),
  )

  let isize = int.bitwise_and(bit_array.byte_size(plain), 0xFFFFFFFF)
  use <- bool.guard(
    when: isize != expected_isize,
    return: Error(error.CodecInvalidData(message: "gzip ISIZE mismatch")),
  )

  Ok(Decoded(header: header, payload: plain))
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

/// Create a new incremental decoder state.  Streaming is not yet
/// implemented; this scaffold exists so the public API stays stable.
pub fn new_decoder() -> Decoder {
  Decoder(header: default_header(), reversed_chunks: [])
}

/// Placeholder chunk push API for future incremental decode.
pub fn push(
  _decoder: Decoder,
  _chunk: BitArray,
) -> Result(#(Decoder, List(BitArray)), error.CodecError) {
  Error(error.CodecNotImplemented(feature: "gzip.push (streaming)"))
}

/// Placeholder finalization API for future incremental decode.
pub fn finish(_decoder: Decoder) -> Result(List(BitArray), error.CodecError) {
  Error(error.CodecNotImplemented(feature: "gzip.finish (streaming)"))
}
