defmodule ContentForge.ContentGeneration.SeoChecklist.Checks.MetaDescriptionLength do
  @moduledoc """
  Meta description length check: a `<meta name="description"
  content="...">` block (or the `meta:` YAML-front-matter
  equivalent) must be 155 characters or fewer so Google does not
  truncate the SERP snippet.

  When no meta description is present, returns `:not_applicable`
  with a note - a separate future check will enforce presence.
  """

  @max_length 155

  def check(%{content: content}) when is_binary(content) do
    case extract_meta_description(content) do
      nil ->
        {:not_applicable, "no meta description in draft"}

      description ->
        len = String.length(description)

        if len <= @max_length do
          {:pass, "meta description #{len} chars"}
        else
          {:fail, "meta description #{len} chars > #{@max_length}"}
        end
    end
  end

  def check(_), do: {:not_applicable, "draft has no content"}

  defp extract_meta_description(content) do
    extract_html_meta(content) || extract_frontmatter_meta(content)
  end

  defp extract_html_meta(content) do
    case Regex.run(
           ~r/<meta\s+name=["']description["']\s+content=["']([^"']+)["']/i,
           content
         ) do
      [_, desc] -> String.trim(desc)
      _ -> nil
    end
  end

  defp extract_frontmatter_meta(content) do
    case Regex.run(~r/^\s*meta(?:_description)?:\s*(.+)$/mi, content) do
      [_, desc] -> String.trim(desc)
      _ -> nil
    end
  end
end
