defmodule ContentForge.ContentGeneration.SeoChecklist.Checks.TocLongArticles do
  @moduledoc """
  Articles over 1500 words must include a Table of Contents,
  detected as a heading whose text contains "Table of Contents"
  or "TOC", OR a `<nav>` with a nested list of anchor links.
  Articles under 1500 words return `:not_applicable`.
  """

  @word_threshold 1500

  def check(%{content: content}) when is_binary(content) do
    word_count = count_words(content)

    cond do
      word_count < @word_threshold ->
        {:not_applicable, "#{word_count} words; TOC optional under #{@word_threshold}"}

      has_toc?(content) ->
        {:pass, "TOC present in #{word_count}-word article"}

      true ->
        {:fail, "no TOC in #{word_count}-word article"}
    end
  end

  def check(_), do: {:not_applicable, "draft has no content"}

  defp count_words(content) do
    content
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  defp has_toc?(content) do
    Regex.match?(~r/table\s+of\s+contents/i, content) or
      Regex.match?(~r/^\s*\#{1,6}\s+.*\bTOC\b.*$/m, content) or
      Regex.match?(~r/<nav[^>]*>[\s\S]*?<(?:ul|ol)\b/i, content)
  end
end
