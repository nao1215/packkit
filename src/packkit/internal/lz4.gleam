//// LZ4 frame format codec.
////
//// Decodes LZ4 frames (magic `0x184D2204`) as specified in the LZ4
//// Frame Format Description.  The encoder runs a greedy 4-byte hash-
//// chain match-finder over each block and emits the LZ77 sequences
//// in the canonical block layout (token byte + optional length
//// extensions + literals + 16-bit little-endian offset + optional
//// match-length extensions).  Blocks that don't shrink are emitted
//// in the uncompressed form to guarantee the frame never grows
//// beyond `1 + ceil(input_size / block_max) * (4 + block_max)`.

import gleam/bit_array
import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/result
import packkit/codec
import packkit/internal/bytes
import packkit/internal/lz77
import packkit/internal/xxh32
import packkit/limit

const magic: Int = 0x184D2204

/// LZ4 legacy frame format magic (`02 21 4C 18` little-endian).
/// The legacy format predates RFC-style LZ4 frames and is still
/// emitted by older `lz4 -l` / `lz4c` tools and embedded systems.
/// It has no frame descriptor, no checksums, no content size — just
/// a magic followed by a sequence of `<size_LE32, body>` blocks
/// terminated at EOF.
const legacy_magic: Int = 0x184C2102

/// LZ4 legacy blocks have an 8 MiB block-size cap per the spec
/// (`LZ4_LEGACY_BLOCKSIZE`).  Going past this would either be an
/// adversarial header or a new concatenated frame, so we use it
/// as an early-exit check during decoding.
const legacy_max_block_size: Int = 8_388_608

const flg_version_mask: Int = 0xC0

const flg_version_v1: Int = 0x40

const flg_block_checksum: Int = 0x10

const flg_content_size: Int = 0x08

const flg_content_checksum: Int = 0x04

const flg_dict_id: Int = 0x01

const uncompressed_block_bit: Int = 0x80000000

const u32_mask: Int = 0xFFFFFFFF

const default_block_max: Int = 4_194_304

/// Encode `bytes` as an LZ4 frame.  The frame descriptor uses
/// independent blocks, the v1 frame version, and a 4 MiB block
/// maximum; no content size, block checksum, content checksum, or
/// dictionary id is written.
pub fn encode(bytes bytes: BitArray) -> Result(BitArray, codec.CodecError) {
  let descriptor = <<0x60, 0x70>>

  let header = <<
    magic:size(32)-little,
    descriptor:bits,
    header_checksum(descriptor),
  >>
  let blocks = encode_blocks(bytes, [])
  let end_mark = <<0:size(32)-little>>
  Ok(bit_array.concat([header, blocks, end_mark]))
}

/// Decode an LZ4 frame using explicit resource limits.
pub fn decode_with_limits(
  bytes bytes: BitArray,
  limits limits: limit.Limits,
) -> Result(BitArray, codec.CodecError) {
  use _ <- result.try(bytes.check_input(bytes, limits))

  case bytes {
    <<m:size(32)-little, after_magic:bytes>> if m == legacy_magic ->
      decode_legacy_blocks(after_magic, <<>>, limits)
    <<m:size(32)-little, flg, bd, rest:bytes>> -> {
      use <- bool.guard(
        when: m != magic,
        return: Error(codec.InvalidData(message: "lz4: bad frame magic")),
      )

      use <- bool.guard(
        when: int.bitwise_and(flg, flg_version_mask) != flg_version_v1,
        return: Error(codec.InvalidData(
          message: "lz4: unsupported frame version",
        )),
      )

      let block_checksum = int.bitwise_and(flg, flg_block_checksum) != 0
      let content_checksum = int.bitwise_and(flg, flg_content_checksum) != 0
      let optional_size =
        case int.bitwise_and(flg, flg_content_size) != 0 {
          True -> 8
          False -> 0
        }
        + case int.bitwise_and(flg, flg_dict_id) != 0 {
          True -> 4
          False -> 0
        }

      let bd_block_max_idx = int.bitwise_and(int.bitwise_shift_right(bd, 4), 7)
      let block_max = block_max_bytes(bd_block_max_idx)

      use rest <- result.try(case rest {
        <<optional:bytes-size(optional_size), hc, rest:bytes>> ->
          case hc == header_checksum(<<flg, bd, optional:bits>>) {
            True -> Ok(rest)
            False ->
              Error(codec.InvalidData(message: "lz4: header checksum mismatch"))
          }
        _ -> Error(codec.InvalidData(message: "lz4: frame header truncated"))
      })

      decode_blocks(
        rest,
        <<>>,
        block_checksum,
        content_checksum,
        block_max,
        limits,
      )
    }
    _ -> Error(codec.InvalidData(message: "lz4: frame header truncated"))
  }
}

// The second byte of the XXH32 of the frame descriptor.
fn header_checksum(descriptor: BitArray) -> Int {
  int.bitwise_and(
    int.bitwise_shift_right(xxh32.digest(bytes: descriptor, seed: 0), 8),
    0xFF,
  )
}

fn encode_blocks(remaining: BitArray, acc: List(BitArray)) -> BitArray {
  let total = bit_array.byte_size(remaining)
  case total {
    0 -> bit_array.concat(list.reverse(acc))
    _ -> {
      let chunk_size = case total > default_block_max {
        True -> default_block_max
        False -> total
      }
      let #(chunk, after) = bytes.split_at(remaining, chunk_size)
      // Try real LZ77 compression first; fall back to an uncompressed
      // block when the result doesn't shrink (or matches the input
      // byte-for-byte) so the frame is never larger than the original
      // payload + framing overhead.
      let compressed = compress_block(chunk, chunk_size)
      let compressed_size = bit_array.byte_size(compressed)
      let framed = case compressed_size < chunk_size {
        True -> <<compressed_size:size(32)-little, compressed:bits>>
        False -> <<
          int.bitwise_or(uncompressed_block_bit, chunk_size):size(32)-little,
          chunk:bits,
        >>
      }
      encode_blocks(after, [framed, ..acc])
    }
  }
}

// -- LZ77 block compressor ---------------------------------------------
//
// The LZ4 block format (Yann Collet's spec) encodes a sequence of
// `(token | optional literal-length extensions | literals | 16-bit
// little-endian offset | optional match-length extensions)` records,
// with the final record carrying only literals.  Two parsing rules
// the reference decoder enforces:
//
// 1. The last 5 bytes of input are always literals.
// 2. The last match must start at least 12 bytes before the end of
//    block.
//
// The encoder runs a greedy 4-byte hash-chain match-finder honouring
// both rules.  Min match length is 4; the stored match length is the
// actual length minus 4 (so the low nibble of the token covers
// matches of length 4..18 inline).

const lz4_min_match: Int = 4

const lz4_max_distance: Int = 65_535

const lz4_last_literals: Int = 5

const lz4_safety_margin: Int = 12

fn compress_block(bytes: BitArray, size: Int) -> BitArray {
  case size <= lz4_safety_margin {
    True -> emit_literal_only_block(bytes, 0, size)
    False -> {
      let table = lz77.table(bytes)
      compress_loop(table, size, 0, 0, dict.new(), [])
    }
  }
}

fn compress_loop(
  table: dict.Dict(Int, Int),
  size: Int,
  pos: Int,
  last_lit_start: Int,
  hashes: dict.Dict(Int, Int),
  acc: List(BitArray),
) -> BitArray {
  let last_search = size - lz4_safety_margin
  case pos > last_search {
    True -> {
      // Tail: emit the remaining bytes as a literal-only sequence.
      let lit_len = size - last_lit_start
      let tail = emit_literal_only_chunk(table, last_lit_start, lit_len)
      bit_array.concat(list.reverse([tail, ..acc]))
    }
    False -> step_compress(table, size, pos, last_lit_start, hashes, acc)
  }
}

fn step_compress(
  table: dict.Dict(Int, Int),
  size: Int,
  pos: Int,
  last_lit_start: Int,
  hashes: dict.Dict(Int, Int),
  acc: List(BitArray),
) -> BitArray {
  let key =
    lz77.hash4(
      lz77.table_at(table, pos),
      lz77.table_at(table, pos + 1),
      lz77.table_at(table, pos + 2),
      lz77.table_at(table, pos + 3),
    )
  case dict.get(hashes, key) {
    Ok(prev) -> {
      let distance = pos - prev
      let valid =
        distance >= 1
        && distance <= lz4_max_distance
        && lz77.same4(table, prev, pos)
      case valid {
        False ->
          compress_loop(
            table,
            size,
            pos + 1,
            last_lit_start,
            dict.insert(hashes, key, pos),
            acc,
          )
        True -> {
          // The last `lz4_last_literals` bytes of the block can't be
          // consumed by a match, so cap the search horizon to keep
          // those bytes for the trailing literal sequence.
          let search_end = size - lz4_last_literals
          let match_len =
            lz77.table_match_length(table, prev, pos, search_end, 0)
          case match_len < lz4_min_match {
            True ->
              compress_loop(
                table,
                size,
                pos + 1,
                last_lit_start,
                dict.insert(hashes, key, pos),
                acc,
              )
            False -> {
              let lit_len = pos - last_lit_start
              let seq =
                emit_sequence(
                  table,
                  last_lit_start,
                  lit_len,
                  distance,
                  match_len,
                )
              let next_pos = pos + match_len
              let new_hashes =
                lz77.insert_hashes4(
                  table,
                  dict.insert(hashes, key, pos),
                  pos + 1,
                  next_pos - 1,
                  size,
                )
              compress_loop(table, size, next_pos, next_pos, new_hashes, [
                seq,
                ..acc
              ])
            }
          }
        }
      }
    }
    _ ->
      compress_loop(
        table,
        size,
        pos + 1,
        last_lit_start,
        dict.insert(hashes, key, pos),
        acc,
      )
  }
}

fn emit_sequence(
  table: dict.Dict(Int, Int),
  lit_start: Int,
  lit_len: Int,
  distance: Int,
  match_len: Int,
) -> BitArray {
  let ml_stored = match_len - lz4_min_match
  let lit_high = case lit_len >= 15 {
    True -> 15
    False -> lit_len
  }
  let ml_high = case ml_stored >= 15 {
    True -> 15
    False -> ml_stored
  }
  let token = int.bitwise_or(int.bitwise_shift_left(lit_high, 4), ml_high)
  let lit_ext = case lit_len >= 15 {
    True -> encode_length_extension(lit_len - 15)
    False -> <<>>
  }
  let literals = lz77.table_slice(table, lit_start, lit_len)
  let offset = <<distance:size(16)-little>>
  let ml_ext = case ml_stored >= 15 {
    True -> encode_length_extension(ml_stored - 15)
    False -> <<>>
  }
  bit_array.concat([<<token>>, lit_ext, literals, offset, ml_ext])
}

fn emit_literal_only_block(bytes: BitArray, start: Int, size: Int) -> BitArray {
  let table = lz77.table(bytes)
  emit_literal_only_chunk(table, start, size)
}

fn emit_literal_only_chunk(
  table: dict.Dict(Int, Int),
  start: Int,
  lit_len: Int,
) -> BitArray {
  let lit_high = case lit_len >= 15 {
    True -> 15
    False -> lit_len
  }
  let token = int.bitwise_shift_left(lit_high, 4)
  let lit_ext = case lit_len >= 15 {
    True -> encode_length_extension(lit_len - 15)
    False -> <<>>
  }
  let literals = lz77.table_slice(table, start, lit_len)
  bit_array.concat([<<token>>, lit_ext, literals])
}

fn encode_length_extension(n: Int) -> BitArray {
  case n {
    n if n < 255 -> <<n>>
    _ -> bit_array.concat([<<0xFF>>, encode_length_extension(n - 255)])
  }
}

// Legacy-frame block driver.  Same Step/Continue trampoline as the
// modern `decode_blocks` so a multi-MB `.lz4` legacy stream decoded on
// the JS target does not exhaust the call stack.
fn decode_legacy_blocks(
  bytes: BitArray,
  output: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, codec.CodecError) {
  case decode_legacy_blocks_step(bytes, output, limits) {
    Error(err) -> Error(err)
    Ok(LegacyBlocksDone(out)) -> Ok(out)
    Ok(LegacyBlocksContinue(next_bytes, next_output)) ->
      decode_legacy_blocks(next_bytes, next_output, limits)
  }
}

type LegacyBlocksStep {
  LegacyBlocksDone(output: BitArray)
  LegacyBlocksContinue(bytes: BitArray, output: BitArray)
}

fn decode_legacy_blocks_step(
  bytes: BitArray,
  output: BitArray,
  limits: limit.Limits,
) -> Result(LegacyBlocksStep, codec.CodecError) {
  case bytes {
    // Stream ends at EOF — there is no terminator block in the
    // legacy format.
    <<>> -> Ok(LegacyBlocksDone(output))
    <<block_size:size(32)-little, _rest:bytes>> if block_size == 0 ->
      // Some implementations write an explicit terminator block;
      // accept it for robustness.
      Ok(LegacyBlocksDone(output))
    <<block_size:size(32)-little, _rest:bytes>>
      if block_size > legacy_max_block_size
    ->
      // Per the legacy spec, a "block size" past 8 MiB indicates
      // either a new concatenated frame magic or junk — stop
      // decoding cleanly rather than allocating a huge slice.
      Ok(LegacyBlocksDone(output))
    <<block_size:size(32)-little, block:bytes-size(block_size), after:bytes>> -> {
      use new_output <- result.try(decode_block(block, output, limits))
      Ok(LegacyBlocksContinue(after, new_output))
    }
    <<_:size(32), _:bytes>> ->
      Error(codec.InvalidData(message: "lz4 legacy: block payload truncated"))
    _ -> Error(codec.InvalidData(message: "lz4 legacy: block header truncated"))
  }
}

// Frame-level driver: one iteration consumes a single block.  Same
// Step/Continue trampoline shape as `decode_block_loop` so the JS
// target stays in constant stack for frames that ship many blocks
// (e.g. a 64 MiB payload at the default 64 KiB block size hits 1024
// blocks, well past the JS recursion budget without the trampoline).
fn decode_blocks(
  bytes: BitArray,
  output: BitArray,
  block_checksum: Bool,
  content_checksum: Bool,
  block_max: Int,
  limits: limit.Limits,
) -> Result(BitArray, codec.CodecError) {
  case
    decode_blocks_step(
      bytes,
      output,
      block_checksum,
      content_checksum,
      block_max,
      limits,
    )
  {
    Error(err) -> Error(err)
    Ok(BlocksDone(out)) -> Ok(out)
    Ok(BlocksContinue(next_bytes, next_output)) ->
      decode_blocks(
        next_bytes,
        next_output,
        block_checksum,
        content_checksum,
        block_max,
        limits,
      )
  }
}

type BlocksStep {
  BlocksDone(output: BitArray)
  BlocksContinue(bytes: BitArray, output: BitArray)
}

fn decode_blocks_step(
  bytes: BitArray,
  output: BitArray,
  block_checksum: Bool,
  content_checksum: Bool,
  block_max: Int,
  limits: limit.Limits,
) -> Result(BlocksStep, codec.CodecError) {
  case bytes {
    <<0:size(32)-little, rest:bytes>> ->
      case finalize(rest, output, content_checksum) {
        Ok(out) -> Ok(BlocksDone(out))
        Error(err) -> Error(err)
      }
    <<header:size(32)-little, rest:bytes>> -> {
      let uncompressed = int.bitwise_and(header, uncompressed_block_bit) != 0
      let block_size =
        int.bitwise_and(
          header,
          int.bitwise_exclusive_or(u32_mask, uncompressed_block_bit),
        )
      use <- bool.guard(
        when: block_size > block_max,
        return: Error(codec.InvalidData(
          message: "lz4: block size exceeds frame max block size",
        )),
      )

      let checksum_size = case block_checksum {
        True -> 4
        False -> 0
      }
      use #(block, stored, after_block) <- result.try(case rest {
        <<
          block:bytes-size(block_size),
          stored:bytes-size(checksum_size),
          after_block:bytes,
        >> -> Ok(#(block, stored, after_block))
        <<_:bytes-size(block_size), _:bytes>> ->
          Error(codec.InvalidData(message: "lz4: block checksum missing"))
        _ -> Error(codec.InvalidData(message: "lz4: block payload truncated"))
      })
      use <- bool.guard(
        when: block_checksum
          && stored != <<xxh32.digest(bytes: block, seed: 0):size(32)-little>>,
        return: Error(codec.InvalidData(message: "lz4: block checksum mismatch")),
      )

      use new_output <- result.try(case uncompressed {
        True -> bytes.append_with_limit(output, block, limits)
        False -> decode_block(block, output, limits)
      })

      Ok(BlocksContinue(after_block, new_output))
    }
    _ -> Error(codec.InvalidData(message: "lz4: block header truncated"))
  }
}

fn finalize(
  after_end: BitArray,
  output: BitArray,
  content_checksum: Bool,
) -> Result(BitArray, codec.CodecError) {
  case content_checksum, after_end {
    False, _ -> Ok(output)
    True, <<stored:size(32)-little, _:bytes>> ->
      case stored == xxh32.digest(bytes: output, seed: 0) {
        True -> Ok(output)
        False ->
          Error(codec.InvalidData(message: "lz4: content checksum mismatch"))
      }
    True, _ ->
      Error(codec.InvalidData(message: "lz4: content checksum missing"))
  }
}

fn decode_block(
  block: BitArray,
  output: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, codec.CodecError) {
  case bit_array.byte_size(block) {
    0 -> Ok(output)
    _ -> decode_block_loop(block, output, limits)
  }
}

// Token-level driver for one LZ4 block.  Wrapped in a Step/Continue
// trampoline (`decode_block_step` / `BlockStep`) because every
// `use ... <- result.try(...)` desugars to a closure on the JS target —
// Gleam's JS backend only rewrites a self-tail-call to a `while` when
// the recursive call sits at the function body's true tail position.
// Without the trampoline, a block carrying more than ~1500 LZ77
// sequences blows up the JS stack (`RangeError: Maximum call stack size
// exceeded`), mirroring the deflate/bzip2 fix in commit 2adc249.
fn decode_block_loop(
  block: BitArray,
  output: BitArray,
  limits: limit.Limits,
) -> Result(BitArray, codec.CodecError) {
  case decode_block_step(block, output, limits) {
    Error(err) -> Error(err)
    Ok(BlockDone(out)) -> Ok(out)
    Ok(BlockContinue(next_block, next_output)) ->
      decode_block_loop(next_block, next_output, limits)
  }
}

type BlockStep {
  BlockDone(output: BitArray)
  BlockContinue(block: BitArray, output: BitArray)
}

fn decode_block_step(
  block: BitArray,
  output: BitArray,
  limits: limit.Limits,
) -> Result(BlockStep, codec.CodecError) {
  case block {
    <<token, rest:bytes>> -> {
      let lit_len_base = int.bitwise_shift_right(token, 4)
      let match_len_base = int.bitwise_and(token, 0x0F)

      use #(lit_len, rest) <- result.try(case lit_len_base {
        15 -> read_extension(rest, 15)
        _ -> Ok(#(lit_len_base, rest))
      })

      case rest {
        <<literals:bytes-size(lit_len), after_literals:bytes>> -> {
          use output <- result.try(bytes.append_with_limit(
            output,
            literals,
            limits,
          ))

          case bit_array.byte_size(after_literals) {
            0 -> Ok(BlockDone(output))
            _ ->
              case after_literals {
                <<offset:size(16)-little, after_offset:bytes>> -> {
                  use <- bool.guard(
                    when: offset == 0,
                    return: Error(codec.InvalidData(
                      message: "lz4: zero match offset",
                    )),
                  )

                  use #(match_len_extra, after_offset) <- result.try(
                    case match_len_base {
                      15 -> read_extension(after_offset, 15)
                      _ -> Ok(#(match_len_base, after_offset))
                    },
                  )

                  let match_len = match_len_extra + 4

                  use <- bool.guard(
                    when: offset > bit_array.byte_size(output),
                    return: Error(codec.InvalidData(
                      message: "lz4: match offset exceeds output",
                    )),
                  )

                  use output <- result.try(bytes.copy_back(
                    output,
                    offset,
                    match_len,
                    limits,
                  ))

                  Ok(BlockContinue(after_offset, output))
                }
                _ ->
                  Error(codec.InvalidData(
                    message: "lz4: match offset truncated",
                  ))
              }
          }
        }
        _ ->
          Error(codec.InvalidData(
            message: "lz4: literal length exceeds block payload",
          ))
      }
    }
    <<>> -> Ok(BlockDone(output))
    _ -> Error(codec.InvalidData(message: "lz4: malformed block"))
  }
}

fn read_extension(
  bytes: BitArray,
  acc: Int,
) -> Result(#(Int, BitArray), codec.CodecError) {
  case bytes {
    <<b, rest:bytes>> ->
      case b {
        0xFF -> read_extension(rest, acc + 0xFF)
        _ -> Ok(#(acc + b, rest))
      }
    _ -> Error(codec.InvalidData(message: "lz4: length extension truncated"))
  }
}

fn block_max_bytes(index: Int) -> Int {
  case index {
    4 -> 64_000
    5 -> 256_000
    6 -> 1_000_000
    7 -> 4_000_000
    _ -> 4_000_000
  }
}
