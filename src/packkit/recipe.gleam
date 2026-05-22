import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import packkit/archive
import packkit/codec
import packkit/error

/// Opaque archive+codec composition.
pub opaque type Recipe {
  Recipe(format: Option(archive.ArchiveFormat), codecs: List(codec.Codec))
}

/// Create a recipe for raw bytes wrapped in a codec chain.
pub fn raw(with first_codec: codec.Codec) -> Recipe {
  Recipe(format: None, codecs: [first_codec])
}

/// Create a recipe that carries an archive but no outer codec yet.
pub fn archive_only(format format: archive.ArchiveFormat) -> Recipe {
  Recipe(format: Some(format), codecs: [])
}

/// Create a recipe with an archive and one outer codec.
pub fn archive_with(
  format format: archive.ArchiveFormat,
  wrapped_by wrapped_by: codec.Codec,
) -> Recipe {
  archive_only(format: format) |> wrap(with: wrapped_by)
}

/// Wrap an existing recipe in one more outer codec.
pub fn wrap(recipe: Recipe, with outer_codec: codec.Codec) -> Recipe {
  Recipe(..recipe, codecs: list.append(recipe.codecs, [outer_codec]))
}

/// Attach an archive format to a raw recipe. Fails if the recipe
/// already contains an archive layer.
pub fn with_archive(
  recipe: Recipe,
  format format: archive.ArchiveFormat,
) -> Result(Recipe, error.RecipeError) {
  case recipe.format {
    Some(existing) ->
      Error(
        error.RecipeArchiveAlreadySet(current: archive.format_name(existing)),
      )
    None -> Ok(Recipe(..recipe, format: Some(format)))
  }
}

/// Convenience constructor for `tar.gz`.
pub fn tar_gzip() -> Recipe {
  archive_with(format: archive.tar(), wrapped_by: codec.gzip())
}

/// Convenience constructor for `tar.zlib`.
pub fn tar_zlib() -> Recipe {
  archive_with(format: archive.tar(), wrapped_by: codec.zlib())
}

/// Convenience constructor for `tar.lz4`.
pub fn tar_lz4() -> Recipe {
  archive_with(format: archive.tar(), wrapped_by: codec.lz4_frame())
}

/// Convenience constructor for `tar.snappy`.
pub fn tar_snappy() -> Recipe {
  archive_with(format: archive.tar(), wrapped_by: codec.snappy_frame())
}

/// Convenience constructor for `cpio.gz`.
pub fn cpio_gzip() -> Recipe {
  archive_with(format: archive.cpio_newc(), wrapped_by: codec.gzip())
}

/// Read the optional archive format.
pub fn archive_format(recipe: Recipe) -> Option(archive.ArchiveFormat) {
  recipe.format
}

/// Read the codec chain in inner-to-outer order.
pub fn codecs(recipe: Recipe) -> List(codec.Codec) {
  recipe.codecs
}

/// Read the outermost codec, if any.
pub fn outermost_codec(recipe: Recipe) -> Option(codec.Codec) {
  last_codec(recipe.codecs)
}

/// Human-readable canonical description for debugging and tests.
pub fn description(recipe: Recipe) -> String {
  let prefix = case recipe.format {
    Some(format) -> [archive.format_name(format)]
    None -> []
  }

  prefix
  |> list.append(list.map(recipe.codecs, codec.name))
  |> string.join(with: ".")
}

fn last_codec(codecs: List(codec.Codec)) -> Option(codec.Codec) {
  case list.reverse(codecs) {
    [codec, ..] -> Some(codec)
    [] -> None
  }
}
