import gleam/list
import gleeunit/should
import packkit
import packkit/archive
import packkit/codec
import packkit/gzip
import packkit/limit

pub fn codec_error_to_string_empty_input_test() -> Nil {
  codec.error_to_string(codec.EmptyInput)
  |> should.equal("codec: empty input")
}

pub fn codec_error_to_string_test() -> Nil {
  codec.error_to_string(codec.InvalidData(message: "truncated"))
  |> should.equal("codec: invalid data: truncated")
  codec.error_to_string(codec.LimitExceeded(
    limit: "max_input_bytes",
    actual: 999,
  ))
  |> should.equal("codec: limit max_input_bytes exceeded (actual 999)")
  codec.error_to_string(codec.DictionaryRequired)
  |> should.equal("codec: the stream needs a preset dictionary")
}

pub fn archive_error_to_string_nests_codec_error_test() -> Nil {
  archive.error_to_string(archive.CodecFailed(
    step: "decode",
    cause: codec.InvalidData(message: "truncated lzma2 stream"),
  ))
  |> should.equal(
    "archive: decode failed: codec: invalid data: truncated lzma2 stream",
  )
}

pub fn archive_error_to_string_format_mismatch_test() -> Nil {
  archive.error_to_string(archive.FormatMismatch(
    archive: archive.Zip,
    requested: archive.Tar,
  ))
  |> should.equal("archive: the archive is zip but tar was requested")
}

pub fn archive_error_to_string_comment_unsupported_test() -> Nil {
  archive.error_to_string(archive.CommentUnsupported(format: archive.Tar))
  |> should.equal("archive: tar cannot store an archive comment")
}

const compressed_codecs = [
  codec.Deflate,
  codec.Zlib,
  codec.Gzip,
  codec.Lz4,
  codec.Snappy,
  codec.Bzip2,
  codec.Lzw,
  codec.Xz,
  codec.Zstd,
  codec.Brotli,
]

// Every compressed format needs at least a header, so empty input is
// invalid, and every codec reports it the same way instead of with a
// format-specific truncation message.
pub fn empty_input_is_the_same_error_for_every_codec_test() -> Nil {
  let empty = codec.EmptyInput
  compressed_codecs
  |> list.each(fn(with) {
    assert packkit.decompress(<<>>, with:) == Error(empty)
    assert packkit.decompress_with_limits(
        <<>>,
        with:,
        limits: limit.Limits(..limit.default(), max_input_bytes: 0),
      )
      == Error(empty)
  })
  assert packkit.decompress(<<>>, with: codec.Identity) == Ok(<<>>)
  assert gzip.decode(<<>>, limits: limit.default()) == Error(empty)
}

pub fn empty_input_through_a_recipe_is_the_same_error_test() -> Nil {
  let recipe = packkit.Recipe(format: archive.Tar, codecs: [codec.Gzip])
  assert packkit.unpack(<<>>, using: recipe)
    == Error(archive.CodecFailed(step: "decode", cause: codec.EmptyInput))
}

// A stream cut off after its first byte is still a truncation, not an
// empty input.
pub fn one_byte_input_is_not_reported_as_empty_test() -> Nil {
  compressed_codecs
  |> list.each(fn(with) {
    assert packkit.decompress(<<0x1f>>, with:) != Error(codec.EmptyInput)
  })
}
