defmodule ContentForge.ContentGeneration.SeoChecklist.Checks.CoreAnswerInFirst150Words do
  @moduledoc """
  The draft's core factual answer must appear within the first
  150 words. Heuristic: the first 150 words must contain at
  least one declarative sentence that ends with a period and is
  at least 40 characters long (roughly a full claim, not a
  question or a one-word opener).

  This works in tandem with the Phase 12.1 AI Summary Nugget,
  which enforces the same idea at a stricter level (first
  paragraph, 100-250 chars, entity-dense). If the nugget passes,
  this check typically passes too; if the nugget was waived,
  this looser check still guards against pure question-openers.
  """

  @word_budget 150

  def check(%{content: content}) when is_binary(content) do
    first = first_n_words(content, @word_budget)

    cond do
      String.length(first) == 0 ->
        {:fail, "draft is empty"}

      question_only?(first) ->
        {:fail, "first 150 words open with a question, no declarative answer"}

      has_declarative_sentence?(first) ->
        {:pass, "declarative answer present in first 150 words"}

      true ->
        {:fail, "no declarative answer sentence in first 150 words"}
    end
  end

  def check(_), do: {:fail, "draft has no content"}

  defp first_n_words(content, n) do
    content
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(n)
    |> Enum.join(" ")
  end

  defp question_only?(text) do
    sentences = split_sentences(text)
    Enum.all?(sentences, &String.ends_with?(&1, "?"))
  end

  defp has_declarative_sentence?(text) do
    text
    |> split_sentences()
    |> Enum.any?(fn sentence ->
      String.ends_with?(sentence, ".") and String.length(sentence) >= 40
    end)
  end

  defp split_sentences(text) do
    text
    |> String.split(~r/(?<=[.!?])\s+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
