//// The gzip header: the original file name, a comment, the modification
//// time and extra subfields. Use `packkit.compress` and
//// `packkit.decompress` when you do not need them.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import packkit/codec
import packkit/internal/bytes
import packkit/internal/checksum
import packkit/internal/deflate
import packkit/limit

const magic_byte_1: Int = 0x1F

const magic_byte_2: Int = 0x8B

const cm_deflate: Int = 8

const fhcrc_flag: Int = 0x02

const fextra_flag: Int = 0x04

const fname_flag: Int = 0x08

const fcomment_flag: Int = 0x10

// RFC 1952 §2.3.1: FLG bits 0x20, 0x40, and 0x80 are reserved and
// MUST be zero.  Reject any header that lights them up.
const flg_reserved_mask: Int = 0xE0

const os_unknown: Int = 0xFF

/// The optional fields of a gzip member header (RFC 1952).
pub type Header {
  Header(
    /// Original file name.
    name: Option(String),
    comment: Option(String),
    /// Modification time in Unix seconds. gzip stores "no time stamp" as
    /// 0, so both `None` and `Some(0)` are written as 0 and read back as
    /// `None`.
    modified_at: Option(Int),
    /// Extra subfields, written in order.
    extra: List(Subfield),
  )
}

/// One extra subfield. `id_1` and `id_2` are the two bytes that name it.
pub type Subfield {
  Subfield(id_1: Int, id_2: Int, data: BitArray)
}

/// Why `encode` could not write a header.
pub type HeaderError {
  NameContainsNul
  CommentContainsNul
  /// The modification time does not fit in 32 bits.
  ModifiedAtOutOfRange(value: Int)
  /// A subfield id byte is outside 0 to 255.
  SubfieldIdOutOfRange(id_1: Int, id_2: Int)
  /// A subfield body is longer than 65,535 bytes.
  SubfieldTooLong(length: Int)
  /// All subfields together are longer than 65,535 bytes.
  ExtraTooLong(length: Int)
}

/// A decoded gzip stream.
pub type Decoded {
  Decoded(
    /// The header of the first member.
    header: Header,
    /// The payloads of all members, joined in order.
    payload: BitArray,
  )
}

/// Compresses `bytes` into a gzip stream with `header`.
///
/// ## Examples
///
/// ```gleam
/// let header =
///   Header(name: Some("report.csv"), comment: None, modified_at: None, extra: [])
/// let assert Ok(bytes) = encode(<<"a,b\n":utf8>>, header:)
/// decode(bytes, limits: limit.default())
/// // -> Ok(Decoded(header:, payload: <<"a,b\n":utf8>>))
/// ```
///
/// ```gleam
/// encode(<<>>, header: Header(..header, name: Some("a\u{0000}b")))
/// // -> Error(NameContainsNul)
/// ```
///
pub fn encode(
  bytes: BitArray,
  header header: Header,
) -> Result(BitArray, HeaderError) {
  use _ <- result.try(check_no_nul(header.name, NameContainsNul))
  use _ <- result.try(check_no_nul(header.comment, CommentContainsNul))
  use _ <- result.try(case header.modified_at {
    Some(value) if value < 0 || value > 0xFFFFFFFF ->
      Error(ModifiedAtOutOfRange(value:))
    _ -> Ok(Nil)
  })
  use _ <- result.try(validate_extra_subfield_ids(header.extra))
  use total <- result.try(measure_extra_subfields(header.extra, 0))
  use <- bool.guard(
    when: total > 0xFFFF,
    return: Error(ExtraTooLong(length: total)),
  )
  Ok(encode_unchecked(bytes, header))
}

fn check_no_nul(
  value: Option(String),
  error: HeaderError,
) -> Result(Nil, HeaderError) {
  case value {
    Some(text) ->
      case string.contains(text, "\u{0000}") {
        True -> Error(error)
        False -> Ok(Nil)
      }
    None -> Ok(Nil)
  }
}

@internal
pub fn encode_without_header(bytes: BitArray) -> BitArray {
  encode_unchecked(bytes, empty_header())
}

fn empty_header() -> Header {
  Header(name: None, comment: None, modified_at: None, extra: [])
}

fn validate_extra_subfield_ids(
  subfields: List(Subfield),
) -> Result(Nil, HeaderError) {
  case subfields {
    [] -> Ok(Nil)
    [Subfield(id_1: id_1, id_2: id_2, data: _), ..rest] ->
      case id_1 < 0 || id_1 > 0xFF || id_2 < 0 || id_2 > 0xFF {
        True -> Error(SubfieldIdOutOfRange(id_1: id_1, id_2: id_2))
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
        True -> Error(SubfieldTooLong(length: len))
        False -> measure_extra_subfields(rest, acc + 4 + len)
      }
    }
  }
}

// The DEFLATE body uses the dynamic-Huffman encoder, which falls back to
// fixed Huffman for inputs it cannot code within 15 bits.
fn encode_unchecked(bytes: BitArray, header: Header) -> BitArray {
  let deflated = deflate.encode_dynamic(bytes: bytes)

  let mtime = case header.modified_at {
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

  bit_array.concat([
    header_bytes,
    extra_block,
    name_block,
    comment_block,
    deflated,
    trailer,
  ])
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

fn encode_extra_subfields(
  subfields: List(Subfield),
  acc: BitArray,
) -> BitArray {
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

/// Decompresses a gzip stream and returns the header with the payload.
/// Use `packkit.decompress` when you only need the payload.
///
/// A stream of several members, such as the output of `cat a.gz b.gz`,
/// returns the header of the first member and the payloads of all
/// members joined. Returns `EmptyInput` for empty input and
/// `InvalidData` when a header, CRC-32 or size check fails.
///
pub fn decode(
  bytes: BitArray,
  limits limits: limit.Limits,
) -> Result(Decoded, codec.CodecError) {
  use <- bool.guard(when: bytes == <<>>, return: Error(codec.EmptyInput))
  use _ <- result.try(bytes.check_input(bytes, limits))

  decode_first_member_and_continue(bytes, limits)
}

fn decode_first_member_and_continue(
  bytes: BitArray,
  limits: limit.Limits,
) -> Result(Decoded, codec.CodecError) {
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
) -> Result(BitArray, codec.CodecError) {
  case bit_array.byte_size(bytes) {
    0 -> Ok(acc)
    _ -> {
      use #(decoded, rest) <- result.try(decode_one_member(bytes, limits))
      let next_size = accumulated_size + bit_array.byte_size(decoded.payload)
      case next_size > limits.max_output_bytes {
        True ->
          Error(codec.LimitExceeded(
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
) -> Result(#(Decoded, BitArray), codec.CodecError) {
  case bytes {
    <<m1, m2, cm, flg, mtime:size(32)-little, _xfl, _os, rest:bytes>> -> {
      use <- bool.guard(
        when: m1 != magic_byte_1 || m2 != magic_byte_2,
        return: Error(codec.InvalidData(message: "gzip magic mismatch")),
      )
      use <- bool.guard(
        when: cm != cm_deflate,
        return: Error(codec.InvalidData(
          message: "gzip compression method is not deflate",
        )),
      )
      // RFC 1952 §2.3.1: FLG bits 0x20 / 0x40 / 0x80 are reserved and
      // "must be zero".  Reject up-front so an unexpected future
      // extension does not silently slip through as if it were valid.
      use <- bool.guard(
        when: int.bitwise_and(flg, flg_reserved_mask) != 0,
        return: Error(codec.InvalidData(message: "gzip reserved FLG bits set")),
      )
      // RFC 1952 §2.3.1: MTIME=0 means "no time stamp available".
      let initial = case mtime {
        0 -> empty_header()
        n -> Header(..empty_header(), modified_at: Some(n))
      }
      decode_header_and_payload(rest, flg, initial, limits, bytes)
    }
    _ -> Error(codec.InvalidData(message: "gzip header truncated"))
  }
}

fn decode_header_and_payload(
  bytes: BitArray,
  flg: Int,
  acc: Header,
  limits: limit.Limits,
  original: BitArray,
) -> Result(#(Decoded, BitArray), codec.CodecError) {
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
  use bytes <- result.try(maybe_verify_header_crc(bytes, flg, original))

  // A name or comment is read up to its NUL terminator, so it never
  // contains one.
  let header =
    Header(..acc, name: name_value, comment: comment_value, extra: extra_value)

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
        return: Error(codec.InvalidData(message: "gzip CRC-32 mismatch")),
      )

      let isize = int.bitwise_and(bit_array.byte_size(plain), 0xFFFFFFFF)
      use <- bool.guard(
        when: isize != expected_isize,
        return: Error(codec.InvalidData(message: "gzip ISIZE mismatch")),
      )

      Ok(#(Decoded(header: header, payload: plain), rest))
    }
    _ -> Error(codec.InvalidData(message: "gzip trailer truncated"))
  }
}

fn maybe_read_extra(
  bytes: BitArray,
  flg: Int,
) -> Result(#(BitArray, List(Subfield)), codec.CodecError) {
  case int.bitwise_and(flg, fextra_flag) {
    0 -> Ok(#(bytes, []))
    _ ->
      case bytes {
        <<xlen:size(16)-little, extra_bytes:bytes-size(xlen), after:bytes>> -> {
          use subfields <- result.try(parse_extra_subfields(extra_bytes, []))
          Ok(#(after, list.reverse(subfields)))
        }
        <<_:size(16), _:bytes>> ->
          Error(codec.InvalidData(message: "gzip extra field truncated"))
        _ -> Error(codec.InvalidData(message: "gzip extra header truncated"))
      }
  }
}

fn parse_extra_subfields(
  bytes: BitArray,
  acc: List(Subfield),
) -> Result(List(Subfield), codec.CodecError) {
  case bit_array.byte_size(bytes) {
    0 -> Ok(acc)
    _ ->
      case bytes {
        <<
          id_1,
          id_2,
          len:size(16)-little,
          data:bytes-size(len),
          remaining:bytes,
        >> ->
          parse_extra_subfields(remaining, [
            Subfield(id_1: id_1, id_2: id_2, data: data),
            ..acc
          ])
        <<_, _, _:size(16), _:bytes>> ->
          Error(codec.InvalidData(message: "gzip extra subfield body truncated"))
        _ ->
          Error(codec.InvalidData(
            message: "gzip extra subfield header truncated",
          ))
      }
  }
}

// Decode a NUL-terminated gzip header string.  RFC 1952 §2.3.1
// specifies the FNAME / FCOMMENT character set as ISO 8859-1
// (LATIN-1).  Modern producers (GNU gzip, libarchive, ...) commonly
// write UTF-8 instead, and most consumers accept both.  We try UTF-8
// first (the common case for names produced by Gleam itself, and what
// most modern tooling emits) and fall back to a 1-to-1
// byte-to-codepoint Latin-1 mapping so RFC-conformant Latin-1
// filenames round-trip cleanly.  The byte 0x00 is the NUL terminator
// and never appears in the payload, so the fallback is unambiguous.
fn maybe_read_string(
  bytes: BitArray,
  flg: Int,
  mask: Int,
) -> Result(#(BitArray, Option(String)), codec.CodecError) {
  case int.bitwise_and(flg, mask) {
    0 -> Ok(#(bytes, None))
    _ ->
      case split_at_nul(bytes, 0) {
        Ok(#(string_bits, after)) -> {
          use decoded <- result.try(
            bit_array.to_string(string_bits)
            // Latin-1 maps every byte to a code point, so this always
            // succeeds and the error below is not reached.
            |> result.lazy_or(fn() { latin1_decode(string_bits, <<>>) })
            |> result.replace_error(codec.InvalidData(
              message: "gzip header string is not text",
            )),
          )
          Ok(#(after, Some(decoded)))
        }
        Error(err) -> Error(err)
      }
  }
}

// RFC 1952 uses ISO 8859-1, which maps each byte to the code point with
// the same value. Bytes from 0x80 take two bytes in UTF-8.
fn latin1_decode(bytes: BitArray, acc: BitArray) -> Result(String, Nil) {
  case bytes {
    <<b, rest:bytes>> if b < 0x80 -> latin1_decode(rest, <<acc:bits, b>>)
    <<b, rest:bytes>> -> {
      let lead = int.bitwise_or(0xC0, int.bitwise_shift_right(b, 6))
      let continuation = int.bitwise_or(0x80, int.bitwise_and(b, 0x3F))
      latin1_decode(rest, <<acc:bits, lead, continuation>>)
    }
    _ -> bit_array.to_string(acc)
  }
}

fn split_at_nul(
  bytes: BitArray,
  offset: Int,
) -> Result(#(BitArray, BitArray), codec.CodecError) {
  case bytes {
    <<prefix:bytes-size(offset), 0, rest:bytes>> -> Ok(#(prefix, rest))
    <<_:bytes-size(offset), _, _:bytes>> -> split_at_nul(bytes, offset + 1)
    _ -> Error(codec.InvalidData(message: "gzip header string missing NUL"))
  }
}

// RFC 1952 §2.3.1: "If FLG.FHCRC is set, a CRC16 for the gzip header
// is present, immediately before the compressed data. The CRC16
// consists of the two least significant bytes of the CRC32 for all
// bytes of the gzip header up to and not including the CRC16."
//
// `original` is the byte buffer this gzip member was decoded from
// (starting at the magic).  At the moment this helper runs, the
// header has been fully consumed except for the optional 2-byte
// CRC16 itself, so the prefix `original[0..header_len]` is exactly
// the byte range the spec covers.
fn maybe_verify_header_crc(
  bytes: BitArray,
  flg: Int,
  original: BitArray,
) -> Result(BitArray, codec.CodecError) {
  case int.bitwise_and(flg, fhcrc_flag) {
    0 -> Ok(bytes)
    _ -> verify_header_crc(bytes, original)
  }
}

fn verify_header_crc(
  bytes: BitArray,
  original: BitArray,
) -> Result(BitArray, codec.CodecError) {
  let header_len = bit_array.byte_size(original) - bit_array.byte_size(bytes)
  use #(expected, rest) <- result.try(read_header_crc16(bytes))
  use header_bytes <- result.try(slice_header_for_crc(original, header_len))
  let actual = int.bitwise_and(checksum.crc32(data: header_bytes), 0xFFFF)
  case actual == expected {
    True -> Ok(rest)
    False -> Error(codec.InvalidData(message: "gzip header CRC16 mismatch"))
  }
}

fn read_header_crc16(
  bytes: BitArray,
) -> Result(#(Int, BitArray), codec.CodecError) {
  case bytes {
    <<expected:size(16)-little, rest:bytes>> -> Ok(#(expected, rest))
    _ -> Error(codec.InvalidData(message: "gzip header CRC missing"))
  }
}

fn slice_header_for_crc(
  original: BitArray,
  header_len: Int,
) -> Result(BitArray, codec.CodecError) {
  case bit_array.slice(original, 0, header_len) {
    Ok(header_bytes) -> Ok(header_bytes)
    Error(_) ->
      Error(codec.InvalidData(message: "gzip header CRC bounds error"))
  }
}
