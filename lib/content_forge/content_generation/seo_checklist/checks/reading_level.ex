defmodule ContentForge.ContentGeneration.SeoChecklist.Checks.ReadingLevel do
  @moduledoc """
  Flesch Reading Ease score must land in the "accessible"
  window (50..80). Below 50 is too dense (academic / corporate
  jargon); above 80 is oversimplified for a blog audience.

  Formula: `206.835 - 1.015 * (words/sentences) - 84.6 * (syllables/words)`

  Syllable count uses a lightweight vowel-group heuristic. Good
  enough for directional feedback; not a clinical reading-level
  tool.
  """

  @min_score 50.0
  @max_score 80.0
  @min_words 30

  def check(%{content: content}) when is_binary(content) do
    plain = strip_markup(content)
    words = split_words(plain)
    word_count = length(words)

    if word_count < @min_words do
      {:not_applicable, "#{word_count} words; need >= #{@min_words} to score reading level"}
    else
      sentences = max(count_sentences(plain), 1)
      syllables = Enum.reduce(words, 0, fn w, acc -> acc + syllables_in(w) end)

      score =
        206.835 - 1.015 * (word_count / sentences) - 84.6 * (syllables / word_count)

      note = "Flesch #{Float.round(score, 1)} (target #{@min_score}-#{@max_score})"

      cond do
        score < @min_score -> {:fail, "too dense: " <> note}
        score > @max_score -> {:fail, "too simple: " <> note}
        true -> {:pass, note}
      end
    end
  end

  def check(_), do: {:fail, "draft has no content"}

  defp strip_markup(content) do
    content
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/[`*_#>|~\[\]\(\)]+/, " ")
  end

  defp split_words(text) do
    text
    |> String.split(~r/[^A-Za-z0-9']+/, trim: true)
    |> Enum.filter(&(&1 != ""))
  end

  defp count_sentences(text) do
    text
    |> String.split(~r/(?<=[.!?])\s+/, trim: true)
    |> Enum.count(fn s -> String.length(String.trim(s)) >= 2 end)
  end

  defp syllables_in(word) do
    lowered = String.downcase(word)

    # Count vowel groups; subtract a silent trailing 'e'; floor at 1.
    groups =
      Regex.scan(~r/[aeiouy]+/, lowered)
      |> length()

    adjusted =
      if String.ends_with?(lowered, "e") and groups > 1 do
        groups - 1
      else
        groups
      end

    max(adjusted, 1)
  end
end
