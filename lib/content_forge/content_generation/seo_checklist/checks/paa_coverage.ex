defmodule ContentForge.ContentGeneration.SeoChecklist.Checks.PaaCoverage do
  @moduledoc """
  Asserts the draft's FAQ section covers the People-Also-Asked
  questions Google surfaces for its primary keyword. Requires
  Apify (SERP source) to be configured; if not, returns
  `:not_applicable`.

  When SERP data becomes available via a future Phase 12.5
  pipeline, the check compares the PAA question set to FAQ
  headings in the draft and reports coverage as a percentage.
  Until then, the configured branch returns `:not_applicable`
  with a note explaining the deferred pipeline dependency.
  """

  alias ContentForge.CompetitorScraper.ApifyAdapter

  def check(%{content: content}) when is_binary(content) do
    case ApifyAdapter.status() do
      :not_configured ->
        {:not_applicable, "Apify (SERP source) not configured"}

      :ok ->
        {:not_applicable,
         "SERP PAA ingestion pipeline not wired yet; check deferred to a future slice"}
    end
  end

  def check(_), do: {:fail, "draft has no content"}
end
