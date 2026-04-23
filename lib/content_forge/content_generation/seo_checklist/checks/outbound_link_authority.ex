defmodule ContentForge.ContentGeneration.SeoChecklist.Checks.OutboundLinkAuthority do
  @moduledoc """
  External links should point at authoritative domains (academic,
  government, major publications, the product's own
  documentation) rather than low-quality aggregators or
  broken-link targets. Evaluating domain authority requires a
  third-party data source (Apify Moz / Ahrefs actor, or a
  cached allowlist).

  Apply a lightweight fallback when Apify is not configured: the
  check passes if every external link is HTTPS (a weak but
  non-zero trust signal). The strict authority check returns
  `:not_applicable` with a note pointing at the future SERP-
  ingestion slice.
  """

  alias ContentForge.CompetitorScraper.ApifyAdapter

  def check(%{content: content}) when is_binary(content) do
    links = extract_external_links(content)

    case {ApifyAdapter.status(), links} do
      {_, []} ->
        {:not_applicable, "no external links to evaluate"}

      {:not_configured, _} ->
        non_https = Enum.count(links, &(not String.starts_with?(&1, "https://")))

        if non_https == 0 do
          {:pass,
           "Apify unavailable; #{length(links)} external links all HTTPS (weak fallback)"}
        else
          {:fail,
           "Apify unavailable; #{non_https}/#{length(links)} external links are not HTTPS"}
        end

      {:ok, _} ->
        {:not_applicable,
         "Apify domain-authority lookup not wired yet; check deferred to a future slice"}
    end
  end

  def check(_), do: {:fail, "draft has no content"}

  defp extract_external_links(content) do
    html =
      Regex.scan(~r/<a\b[^>]*href\s*=\s*["']([a-z]+:\/\/[^"']+)["']/i, content,
        capture: :all_but_first
      )
      |> Enum.map(fn [href] -> href end)

    md =
      Regex.scan(~r/(?<!\!)\[[^\]]+\]\(([a-z]+:\/\/[^)\s]+)\)/, content,
        capture: :all_but_first
      )
      |> Enum.map(fn [href] -> href end)

    html ++ md
  end
end
