defmodule ContentForge.ContentGeneration.SeoChecklist.Checks.FastScanSummaryFirst200 do
  @moduledoc """
  The first 200 words must contain a scannable summary. This
  check links to the existing Phase 12.1 AI Summary Nugget - if
  the draft has a populated `ai_summary_nugget`, the summary
  constraint is already satisfied (the nugget validator is
  strictly tighter than what this check would enforce). Drafts
  that lack a nugget fall back to a lightweight heuristic: at
  least two complete sentences in the first 200 words.
  """

  @word_budget 200

  def check(%{ai_summary_nugget: nugget}) when is_binary(nugget) and nugget != "" do
    {:pass, "linked to AI Summary Nugget (#{String.length(nugget)} chars)"}
  end

  def check(%{content: content}) when is_binary(content) do
    window = first_n_words(content, @word_budget)
    sentence_count = count_sentences(window)

    if sentence_count >= 2 do
      {:pass, "#{sentence_count} sentences in first #{@word_budget} words"}
    else
      {:fail, "only #{sentence_count} complete sentences in first #{@word_budget} words"}
    end
  end

  def check(_), do: {:fail, "draft has no content"}

  defp first_n_words(content, n) do
    content
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(n)
    |> Enum.join(" ")
  end

  defp count_sentences(text) do
    text
    |> String.split(~r/(?<=[.!?])\s+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(fn s -> String.length(s) >= 20 and String.ends_with?(s, [".", "!", "?"]) end)
    |> length()
  end
end
