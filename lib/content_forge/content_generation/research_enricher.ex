defmodule ContentForge.ContentGeneration.ResearchEnricher do
  @moduledoc """
  Phase 12.3: injects an Original Research block into blog
  drafts. Tries three data sources in priority order, first hit
  wins:

    1. `Metrics.ScoreboardEntry` - the product's own winning
       content (AI-measured performance).
    2. `Products.CompetitorIntel` - trending topics scraped
       from the product's competitors.
    3. `Products.ProductSnapshot` - content summary from repo /
       site crawls.

  On a hit, the LLM writes a 2-3 sentence research block that
  must cite the chosen data point verbatim. A substring check
  guards against LLM hallucination: if the response doesn't
  contain the data-point string, the draft flips to
  `needs_review` and no block is injected. Never fabricates.

  Non-blog drafts pass through unchanged. If no source yields a
  data point, the draft is tagged `research_status: "no_data"`
  without an LLM call. If the LLM is `:not_configured`, returns
  `{:error, :not_configured}` without touching the draft.

  The LLM adapter is configurable via:

      config :content_forge, :research_enricher_llm,
        {MyAdapter, opts}

  Default is the production `ContentForge.LLM.Anthropic`. Tests
  stub this to assert hallucination + not_configured branches
  without hitting live HTTP.
  """

  alias ContentForge.ContentGeneration
  alias ContentForge.ContentGeneration.Draft
  alias ContentForge.LLM.Anthropic
  alias ContentForge.Metrics
  alias ContentForge.Metrics.ScoreboardEntry
  alias ContentForge.Products
  alias ContentForge.Products.CompetitorIntel
  alias ContentForge.Products.ProductSnapshot
  alias ContentForge.Repo

  @block_header "## Original Research"

  def enrich(%Draft{content_type: "blog"} = draft) do
    case llm_status() do
      :not_configured ->
        {:error, :not_configured}

      :ok ->
        dispatch_on_data(draft, find_data_point(draft))
    end
  end

  def enrich(%Draft{} = draft), do: {:ok, draft}

  defp dispatch_on_data(draft, :no_data), do: mark_no_data(draft)

  defp dispatch_on_data(draft, {:ok, source, data_point}) do
    case call_llm(source, data_point) do
      {:ok, text} ->
        if String.contains?(text, data_point) do
          write_enriched(draft, source, text)
        else
          flag_lost_data_point(draft, source, data_point)
        end

      {:error, :not_configured} ->
        {:error, :not_configured}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- data-point discovery --------------------------------------------------

  defp find_data_point(%Draft{product_id: product_id}) do
    with :miss <- try_scoreboard(product_id),
         :miss <- try_competitor_intel(product_id),
         :miss <- try_product_snapshot(product_id) do
      :no_data
    end
  end

  defp try_scoreboard(product_id) do
    case Metrics.list_scoreboard_entries(product_id: product_id, outcome: "winner", limit: 1) do
      [%ScoreboardEntry{delta: delta, platform: platform} = _entry] when is_float(delta) ->
        phrase =
          "#{Float.round(delta, 1)} points above average engagement on #{platform}"

        {:ok, "scoreboard", phrase}

      _ ->
        :miss
    end
  end

  defp try_competitor_intel(product_id) do
    case Products.list_competitor_intel_for_product(product_id) do
      [%CompetitorIntel{trending_topics: [topic | _]} = _intel | _] when is_binary(topic) ->
        {:ok, "competitor_intel", topic}

      _ ->
        :miss
    end
  end

  defp try_product_snapshot(product_id) do
    case Products.list_product_snapshots_for_product(product_id) do
      [%ProductSnapshot{content_summary: summary} | _]
      when is_binary(summary) and byte_size(summary) > 0 ->
        {:ok, "product_snapshot", summary}

      _ ->
        :miss
    end
  end

  # --- LLM call --------------------------------------------------------------

  defp call_llm(source, data_point) do
    prompt = build_prompt(source, data_point)

    case llm_complete(prompt) do
      {:ok, %{text: text}} -> {:ok, text}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_prompt(source, data_point) do
    """
    Write a 2-3 sentence "Original Research" block for a blog article.

    Cite the following data point verbatim, word for word, exactly as
    written below. Do NOT paraphrase, round, or rephrase any number
    or name.

    Data point: #{data_point}
    Source: #{source}

    The data point string must appear in your response exactly as
    given. Keep the block under 400 characters. No preamble.
    """
  end

  # --- draft mutations -------------------------------------------------------

  defp write_enriched(draft, source, text) do
    new_content = inject_block(draft.content, text)

    draft
    |> Draft.changeset(%{
      content: new_content,
      research_status: "enriched",
      research_source: source
    })
    |> Repo.update()
  end

  defp flag_lost_data_point(draft, source, data_point) do
    existing_error = draft.error || ""

    new_error =
      [existing_error, "research lost_data_point (#{source}): #{data_point}"]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" | ")

    result =
      draft
      |> Draft.changeset(%{
        research_status: "lost_data_point",
        status: "needs_review",
        error: new_error
      })
      |> Repo.update()

    case result do
      {:ok, updated} -> {:error, :lost_data_point, updated}
      {:error, changeset} -> {:error, {:lost_data_point_persist_failed, changeset}}
    end
  end

  defp mark_no_data(draft) do
    result =
      draft
      |> Draft.changeset(%{research_status: "no_data"})
      |> Repo.update()

    case result do
      {:ok, updated} -> {:ok, :no_data, updated}
      other -> other
    end
  end

  defp inject_block(content, block_text) do
    # Append a fenced Original Research block after the existing
    # content. The nugget paragraph and everything the SEO
    # checklist already evaluated stays intact above the
    # injection point.
    content
    |> String.trim_trailing()
    |> Kernel.<>("\n\n#{@block_header}\n\n#{String.trim(block_text)}\n")
  end

  # --- LLM adapter indirection ----------------------------------------------

  defp llm_status do
    case llm_impl() do
      {module, opts} -> module.status(opts)
      :default -> Anthropic.status()
    end
  end

  defp llm_complete(prompt) do
    case llm_impl() do
      {module, opts} -> module.complete(prompt, [], opts)
      :default -> Anthropic.complete(prompt)
    end
  end

  defp llm_impl do
    Application.get_env(:content_forge, :research_enricher_llm, :default)
  end

  @doc false
  def _reload(%Draft{id: id}), do: ContentGeneration.get_draft!(id)
end
