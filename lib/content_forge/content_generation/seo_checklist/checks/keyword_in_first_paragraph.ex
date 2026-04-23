defmodule ContentForge.ContentGeneration.SeoChecklist.Checks.KeywordInFirstParagraph do
  @moduledoc """
  The H1 title's primary keyword must appear in the first
  paragraph of the body. Heuristic: the longest substantive
  (non-stopword, >= 4 char) word from the title must appear in
  the first paragraph after the title.
  """

  @stopwords ~w(the a an of to in for and or with from this that how what why when where as is are was were be been being your our their its my me you we they it us i)
  @min_keyword_length 4

  def check(%{content: content}) when is_binary(content) do
    case extract_title(content) do
      nil ->
        {:not_applicable, "no H1 in draft"}

      title ->
        first_paragraph = first_paragraph_below_title(content)
        keywords = title_keywords(title)

        cond do
          keywords == [] ->
            {:fail, "title has no substantive keyword"}

          first_paragraph in [nil, ""] ->
            {:fail, "no body paragraph after title"}

          Enum.any?(keywords, &String.contains?(String.downcase(first_paragraph), &1)) ->
            {:pass, "title keyword appears in first paragraph"}

          true ->
            {:fail, "no title keyword in first paragraph"}
        end
    end
  end

  def check(_), do: {:not_applicable, "draft has no content"}

  defp extract_title(content) do
    case Regex.run(~r/^\s*#\s+(.+)$/m, content) do
      [_, title] -> String.trim(title)
      _ -> nil
    end
  end

  defp title_keywords(title) do
    title
    |> String.downcase()
    |> String.split(~r/[^\w]+/, trim: true)
    |> Enum.filter(&(String.length(&1) >= @min_keyword_length and &1 not in @stopwords))
  end

  defp first_paragraph_below_title(content) do
    content
    |> String.replace(~r/^\s*#\s+.+$/m, "", global: false)
    |> String.trim_leading()
    |> String.split(~r/\n\s*\n/, parts: 2)
    |> List.first()
    |> Kernel.||("")
  end
end
