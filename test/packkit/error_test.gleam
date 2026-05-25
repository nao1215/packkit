import gleeunit/should
import packkit/error

pub fn format_codec_error_invalid_data_test() -> Nil {
  error.format_codec_error(error.CodecInvalidData(message: "truncated"))
  |> should.equal("codec: invalid data — truncated")
}

pub fn format_codec_error_limit_exceeded_test() -> Nil {
  error.format_codec_error(error.CodecLimitExceeded(
    limit: "max_input_bytes",
    actual: 999,
  ))
  |> should.equal("codec: limit \"max_input_bytes\" exceeded (actual=999)")
}

pub fn format_codec_error_option_unsupported_test() -> Nil {
  error.format_codec_error(error.CodecOptionUnsupported(
    option: "level",
    codec_name: "lz4",
  ))
  |> should.equal("codec: lz4 does not support the requested option \"level\"")
}

pub fn format_archive_error_codec_failed_test() -> Nil {
  // The nested CodecError must render through format_codec_error,
  // not through string.inspect — otherwise downstream CLIs would
  // leak the constructor names back to end users.
  error.format_archive_error(error.ArchiveCodecFailed(
    step: "decode",
    cause: error.CodecInvalidData(message: "truncated lzma2 stream"),
  ))
  |> should.equal(
    "archive: decode step — codec: invalid data — truncated lzma2 stream",
  )
}

pub fn format_archive_error_format_mismatch_test() -> Nil {
  error.format_archive_error(error.ArchiveFormatMismatch(
    archive: "zip",
    requested: "tar",
  ))
  |> should.equal(
    "archive: format mismatch (archive was built as \"zip\" but \"tar\" was requested)",
  )
}

pub fn format_detect_error_test() -> Nil {
  error.format_detect_error(error.DetectUnknownFormat(input: "random.txt"))
  |> should.equal("detect: could not classify input \"random.txt\"")
}

pub fn format_recipe_error_test() -> Nil {
  error.format_recipe_error(error.RecipeEmptyCodecChain)
  |> should.equal("recipe: codec chain is empty")
}
