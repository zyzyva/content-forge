defmodule ContentForge.ContentGeneration.SeoChecklist.Checks.TitleLength do
  @moduledoc """
  SEO title length check: the first heading (H1) of the draft
  must be 60 characters or fewer, which is the SERP snippet
  cut-off for most search engines.

  Looks for either a markdown `# ...` line or an HTML `<h1>...</h1>`
  tag. If neither exists, the check returns `:not_applicable`
  because a different check (`SingleH1`) is responsible for
  surfacing the missing-H1 failure.
  """

  @max_length 60

  def check(%{content: content}) when is_binary(content) do
    case extract_title(content) do
      nil ->
        {:not_applicable, "no H1 in draft"}

      title ->
        len = String.length(title)

        if len <= @max_length do
          {:pass, "title #{len} chars"}
        else
          {:fail, "title #{len} chars > #{@max_length}"}
        end
    end
  end

  def check(_), do: {:not_applicable, "draft has no content"}

  defp extract_title(content) do
    extract_markdown_h1(content) || extract_html_h1(content)
  end

  defp extract_markdown_h1(content) do
    case Regex.run(~r/^\s*#\s+(.+)$/m, content) do
      [_, title] -> String.trim(title)
      _ -> nil
    end
  end

  defp extract_html_h1(content) do
    case Regex.run(~r/<h1[^>]*>(.+?)<\/h1>/is, content) do
      [_, title] -> title |> String.trim() |> strip_tags()
      _ -> nil
    end
  end

  defp strip_tags(text), do: Regex.replace(~r/<[^>]+>/, text, "")
end
