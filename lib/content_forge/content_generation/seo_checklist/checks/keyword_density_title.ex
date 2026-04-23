defmodule ContentForge.ContentGeneration.SeoChecklist.Checks.KeywordDensityTitle do
  @moduledoc """
  Heuristic "keyword in title" check without an explicit
  keyword field: the H1 must contain at least one substantive
  word (>= 4 characters, not a stopword) that also appears in
  the first 300 words of the body. If no H1 exists, returns
  `:not_applicable` - SingleH1 owns that failure.
  """

  @stopwords ~w(the a an of to in for and or with from this that how what why when where as is are was were be been being your our their its my me you we they it us i)
  @min_keyword_length 4
  @body_window_words 300

  def check(%{content: content}) when is_binary(content) do
    case extract_title(content) do
      nil ->
        {:not_applicable, "no H1 in draft"}

      title ->
        body_window = body_first_words(content, @body_window_words)
        keywords = title_keywords(title)

        cond do
          keywords == [] ->
            {:fail, "title has no substantive keyword"}

          Enum.any?(keywords, &String.contains?(body_window, &1)) ->
            {:pass, "title keyword appears in first #{@body_window_words} body words"}

          true ->
            {:fail, "no title keyword in first #{@body_window_words} body words"}
        end
    end
  end

  def check(_), do: {:not_applicable, "draft has no content"}

  defp extract_title(content) do
    case Regex.run(~r/^\s*#\s+(.+)$/m, content) do
      [_, title] ->
        String.trim(title)

      _ ->
        case Regex.run(~r/<h1[^>]*>(.+?)<\/h1>/is, content) do
          [_, title] ->
            title
            |> String.trim()
            |> then(&Regex.replace(~r/<[^>]+>/, &1, ""))

          _ ->
            nil
        end
    end
  end

  defp title_keywords(title) do
    lowered = String.downcase(title)

    lowered
    |> String.split(~r/[^\w]+/, trim: true)
    |> Enum.filter(&(String.length(&1) >= @min_keyword_length and &1 not in @stopwords))
  end

  defp body_first_words(content, n) do
    content
    # Strip the first H1 line so the title itself does not count.
    |> String.replace(~r/^\s*#\s+.+$/m, "", global: false)
    |> String.replace(~r/<h1[^>]*>.+?<\/h1>/is, "")
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(n)
    |> Enum.join(" ")
  end
end
