defmodule ContentForge.ContentGeneration.SeoChecklist.Checks.SlugLength do
  @moduledoc """
  If the draft includes a `slug:` frontmatter line or an
  `{:slug "..."}` hint anywhere in the content, require it to be
  <= 75 characters. No slug -> `:not_applicable` (Phase 12.4
  dashboard will let operators set the slug before publish).
  """

  @max 75

  def check(%{content: content}) when is_binary(content) do
    case extract_slug(content) do
      nil ->
        {:not_applicable, "no slug in draft"}

      slug ->
        len = String.length(slug)

        if len <= @max do
          {:pass, "slug #{len} chars"}
        else
          {:fail, "slug #{len} chars > #{@max}"}
        end
    end
  end

  def check(_), do: {:not_applicable, "draft has no content"}

  defp extract_slug(content) do
    case Regex.run(~r/^\s*slug:\s*([^\s]+)\s*$/mi, content) do
      [_, slug] -> slug
      _ -> nil
    end
  end
end
