defmodule ContentForge.ContentGeneration.SeoChecklist.Checks.EntityDensity do
  @moduledoc """
  Counts entity-style tokens (proper nouns + numeric tokens)
  across the body and asserts a density floor of 1 entity per 30
  words. Helps flag blog drafts that read like generic essays
  instead of fact-dense reporting.

  Proper-noun detection uses the same multi-cap / hyphenated /
  not-a-common-opener heuristic as the Phase 12.1 nugget
  validator so the two stay consistent.
  """

  @words_per_entity 30
  @common_words ~w(This That These Those The A An It They We You I And But Or If Then When Where Why How What Who)

  def check(%{content: content}) when is_binary(content) do
    plain = strip_markup(content)
    words = split_words(plain)
    word_count = length(words)

    if word_count == 0 do
      {:fail, "draft has no body text"}
    else
      entities = Enum.count(words, &entity_token?/1)
      required = max(div(word_count, @words_per_entity), 1)

      if entities >= required do
        {:pass, "#{entities} entities in #{word_count} words (>=1 per #{@words_per_entity})"}
      else
        {:fail,
         "#{entities} entities in #{word_count} words (need >= #{required})"}
      end
    end
  end

  def check(_), do: {:fail, "draft has no content"}

  defp strip_markup(content) do
    content
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/[`*_#>|~]+/, " ")
  end

  defp split_words(text), do: String.split(text, ~r/[\s,.;:!?()\[\]]+/, trim: true)

  defp entity_token?(token) do
    numeric?(token) or proper_noun?(token)
  end

  defp numeric?(token), do: Regex.match?(~r/\d/, token)

  defp proper_noun?(token) do
    case token do
      <<first::utf8, _rest::binary>> when first in ?A..?Z ->
        multi_cap?(token) or String.contains?(token, "-") or token not in @common_words

      _ ->
        false
    end
  end

  defp multi_cap?(token) do
    String.graphemes(token)
    |> Enum.count(fn g -> g =~ ~r/[A-Z]/ end)
    |> Kernel.>=(2)
  end
end
