defmodule ContentForge.ContentGeneration.SeoChecklist.Checks.InternalLinks do
  @moduledoc """
  The draft must include at least one internal link. An internal
  link is any href that is relative (starts with `/` or does not
  include a scheme) or markdown `[...](/path)` form. Pure anchor
  links (`#fragment`) do not count - those are navigation within
  the article, not cross-article connective tissue.
  """

  @min_internal 1

  def check(%{content: content}) when is_binary(content) do
    count = count_internal_links(content)

    if count >= @min_internal do
      {:pass, "#{count} internal link(s)"}
    else
      {:fail, "no internal links (expected >= #{@min_internal})"}
    end
  end

  def check(_), do: {:fail, "draft has no content"}

  defp count_internal_links(content) do
    html = extract_html_hrefs(content)
    md = extract_markdown_hrefs(content)

    (html ++ md)
    |> Enum.count(&internal?/1)
  end

  defp extract_html_hrefs(content) do
    Regex.scan(~r/<a\b[^>]*href\s*=\s*["']([^"']+)["']/i, content, capture: :all_but_first)
    |> Enum.map(fn [href] -> href end)
  end

  defp extract_markdown_hrefs(content) do
    Regex.scan(~r/(?<!\!)\[[^\]]+\]\(([^)\s]+)\)/, content, capture: :all_but_first)
    |> Enum.map(fn [href] -> href end)
  end

  defp internal?("#" <> _), do: false
  defp internal?("/" <> _), do: true
  defp internal?(href), do: not Regex.match?(~r|^[a-z]+://|i, href)
end
