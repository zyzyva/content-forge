defmodule ContentForge.Jobs.CompetitorIntelSynthesizer do
  @moduledoc """
  Oban job that synthesizes top-performing competitor posts into a
  competitor intel summary by calling a smart-model adapter.

  The smart-model adapter is configured via `:content_forge,
  :intel_model` and must implement a `summarize/1` function returning
  `{:ok, %{summary, trending_topics, winning_formats, effective_hooks,
  audience_signals}}` (Phase 17.4 added `audience_signals`).

  ## Args

      %{
        "product_id" => binary_id,
        "window" => "all" | "week" | "month"  # optional; default "all"
      }

  ## Phase 17.4 routes

  - **With key**: adapter returns `{:ok, intel}`. The job persists a
    `competitor_intel` row carrying the new `audience_signals` and
    `window` columns, and resolves any matching pending-synthesis
    rows for the same `(product_id, window)`.
  - **Without key**: adapter returns `{:error, :not_configured}`.
    The job inserts a `pending_intel_syntheses` row pointing at the
    source posts, then `:discard`s so Oban does not retry against a
    permanent misconfiguration. A Claude Code session uses the MCP
    server to read the bundle (via `cf_top_posts_for_synthesis`)
    and submit the manual synthesis (via `cf_store_intel`), which
    deletes the pending row.

  Behaviour without an `:intel_model` adapter wired (older boots)
  also routes to `pending_manual` so the without-key path is the
  single fallback signal.
  """
  use Oban.Worker, queue: :competitor, max_attempts: 3

  require Logger

  alias ContentForge.Products
  alias ContentForge.Repo

  @top_posts_limit 10
  @windows ~w(all week month)
  @default_window "all"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"product_id" => product_id} = args}) do
    window = fetch_window(args)
    synthesize_for_product(product_id, intel_model(), window)
  end

  defp synthesize_for_product(product_id, nil, window) do
    Logger.info(
      "CompetitorIntelSynthesizer: no intel_model configured for product #{product_id}; routing to pending_manual"
    )

    record_pending(product_id, window, [], "intel_model not configured")
    {:discard, :intel_model_not_configured}
  end

  defp synthesize_for_product(product_id, adapter, window) do
    Logger.info(
      "Starting competitor intel synthesis for product #{product_id} (window=#{window})"
    )

    with {:ok, _product} <- fetch_product(product_id),
         {:ok, top_posts} <- fetch_top_posts(product_id),
         {:ok, analysis} <- summarize(adapter, top_posts, product_id) do
      store_intel(product_id, top_posts, analysis, window)
      Logger.info("Competitor intel synthesis completed for product #{product_id}")
      :ok
    else
      :skipped ->
        :ok

      {:error, :not_configured} ->
        # Without-key route: log a pending-synthesis row so the MCP
        # surface can find work to do, then discard the Oban job
        # rather than retrying a permanent misconfiguration.
        top_post_ids =
          case fetch_top_posts(product_id) do
            {:ok, posts} -> Enum.map(posts, & &1.id)
            _ -> []
          end

        record_pending(product_id, window, top_post_ids, "ANTHROPIC_API_KEY not configured")
        {:discard, :not_configured}

      {:error, reason} ->
        Logger.error("Competitor intel synthesis failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fetch_product(product_id) do
    case Products.get_product(product_id) do
      nil -> {:error, :not_found}
      product -> {:ok, product}
    end
  end

  defp fetch_top_posts(product_id) do
    posts =
      product_id
      |> Products.list_top_competitor_posts_for_product(@top_posts_limit)
      |> Repo.preload(:comments)

    {:ok, posts}
  end

  defp summarize(_adapter, [], product_id) do
    Logger.info("No competitor posts to analyze for product #{product_id}")
    :skipped
  end

  defp summarize(adapter, posts, _product_id) do
    adapter.summarize(posts)
  end

  defp store_intel(product_id, posts, analysis, window) do
    persisted = persisted_window(window)

    {:ok, _intel} =
      Products.create_competitor_intel(%{
        product_id: product_id,
        summary: analysis.summary,
        source_count: length(posts),
        trending_topics: analysis.trending_topics,
        winning_formats: analysis.winning_formats,
        effective_hooks: analysis.effective_hooks,
        audience_signals: Map.get(analysis, :audience_signals, []),
        window: persisted
      })

    Products.resolve_pending_intel_syntheses(product_id, persisted)
    :ok
  end

  defp record_pending(product_id, window, source_post_ids, note) do
    Products.create_pending_intel_synthesis(%{
      product_id: product_id,
      window: persisted_window(window),
      source_post_ids: source_post_ids,
      note: note
    })
  end

  defp fetch_window(%{"window" => value}) when value in @windows, do: value
  defp fetch_window(_), do: @default_window

  defp persisted_window(value) when value in @windows, do: value
  defp persisted_window(_), do: nil

  defp intel_model, do: Application.get_env(:content_forge, :intel_model)
end
