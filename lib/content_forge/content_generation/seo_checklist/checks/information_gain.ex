defmodule ContentForge.ContentGeneration.SeoChecklist.Checks.InformationGain do
  @moduledoc """
  Compares the draft against its competitive landscape and
  returns a pass when the draft contains substantive information
  not present in the top-10 SERP results for its primary
  keyword.

  Requires BOTH `LLM.Anthropic` and `ApifyAdapter` to be
  configured. When either is missing, returns
  `:not_applicable` with a clear note - no synthetic pass/fail.

  SERP ingestion itself is not implemented in this slice; the
  check defers to a future Phase 12.5 SERP-ingestion slice. When
  SERP data lands alongside a draft, this check swaps from the
  "SERP data unavailable" branch to a real comparison.
  """

  alias ContentForge.CompetitorScraper.ApifyAdapter
  alias ContentForge.LLM.Anthropic

  def check(%{content: content}) when is_binary(content) do
    cond do
      Anthropic.status() == :not_configured ->
        {:not_applicable, "LLM not configured"}

      ApifyAdapter.status() == :not_configured ->
        {:not_applicable, "Apify (SERP source) not configured"}

      true ->
        {:not_applicable,
         "SERP ingestion pipeline not wired yet; check deferred to a future slice"}
    end
  end

  def check(_), do: {:fail, "draft has no content"}
end
