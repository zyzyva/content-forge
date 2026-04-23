defmodule ContentForge.ContentGeneration.SeoChecklist.Checks.CitationPresence do
  @moduledoc """
  Require at least one citation per major claim. Heuristic:

    * Count numeric claims (percentages, prices, explicit counts,
      dates) in the body.
    * Count external citations - absolute-scheme hrefs OR
      footnote-style `[1]` / `(Source: X)` markers OR
      `<cite>...</cite>` tags.
    * Pass when citations >= ceil(numeric_claims / 3). The 1:3
      ratio is the default cadence; dense fact articles still
      surface as passes, pure opinion pieces with no numbers hit
      the `:not_applicable` path.
  """

  def check(%{content: content}) when is_binary(content) do
    plain = strip_markup(content)
    claims = count_numeric_claims(plain)

    case claims do
      0 ->
        {:not_applicable, "no numeric claims to cite"}

      _ ->
        citations = count_citations(content)
        required = Float.ceil(claims / 3.0) |> trunc()

        if citations >= required do
          {:pass, "#{citations} citations for #{claims} numeric claim(s)"}
        else
          {:fail,
           "#{citations} citations for #{claims} numeric claim(s) (need >= #{required})"}
        end
    end
  end

  def check(_), do: {:fail, "draft has no content"}

  defp strip_markup(content) do
    content
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/[`*_#>|~\[\]\(\)]+/, " ")
  end

  defp count_numeric_claims(plain) do
    percent = Regex.scan(~r/\b\d+(\.\d+)?\s*%/, plain) |> length()
    price = Regex.scan(~r/\$\s?\d/, plain) |> length()
    year = Regex.scan(~r/\b(19|20)\d{2}\b/, plain) |> length()
    plain_num = Regex.scan(~r/\b\d{2,}\b/, plain) |> length()

    percent + price + year + plain_num
  end

  defp count_citations(content) do
    ext_links =
      Regex.scan(~r/<a\b[^>]*href\s*=\s*["']([a-z]+:\/\/[^"']+)["']/i, content)
      |> length()

    md_links = Regex.scan(~r/(?<!\!)\[[^\]]+\]\([a-z]+:\/\/[^)\s]+\)/, content) |> length()
    cite_tags = Regex.scan(~r/<cite\b[^>]*>/i, content) |> length()
    footnotes = Regex.scan(~r/\[\d+\]/, content) |> length()

    ext_links + md_links + cite_tags + footnotes
  end
end
