import gleeunit/should
import packkit/archive
import packkit/codec

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
