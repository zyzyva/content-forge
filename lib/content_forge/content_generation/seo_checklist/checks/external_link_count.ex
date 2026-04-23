defmodule ContentForge.ContentGeneration.SeoChecklist.Checks.ExternalLinkCount do
  @moduledoc """
  The draft should include a reasonable number of external links:
  at least 1 to anchor claims against authoritative sources, at
  most 20 so the article does not turn into a link farm. The
  `OutboundLinkAuthority` check (12.2c) evaluates the quality of
  the destinations separately.
  """

  @min 1
  @max 20

  def check(%{content: content}) when is_binary(content) do
    count = count_external(content)

    cond do
      count < @min -> {:fail, "#{count} external links (expected >= #{@min})"}
      count > @max -> {:fail, "#{count} external links (expected <= #{@max})"}
      true -> {:pass, "#{count} external links"}
    end
  end

  def check(_), do: {:fail, "draft has no content"}

  defp count_external(content) do
    html =
      Regex.scan(~r/<a\b[^>]*href\s*=\s*["']([^"']+)["']/i, content, capture: :all_but_first)
      |> Enum.map(fn [href] -> href end)

    md =
      Regex.scan(~r/(?<!\!)\[[^\]]+\]\(([^)\s]+)\)/, content, capture: :all_but_first)
      |> Enum.map(fn [href] -> href end)

    (html ++ md)
    |> Enum.count(&external?/1)
  end

  defp external?(href), do: Regex.match?(~r|^[a-z]+://|i, href)
end
