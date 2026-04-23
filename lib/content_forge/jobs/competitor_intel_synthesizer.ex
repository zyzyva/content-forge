defmodule ContentForge.Jobs.CompetitorIntelSynthesizer do
  @moduledoc """
  Oban job that synthesizes top-performing competitor posts into a competitor
  intel summary by calling a smart model adapter.

  The smart-model adapter is configured via `:content_forge, :intel_model`
  and must implement a `summarize/1` function returning
  `{:ok, %{summary: String.t(), trending_topics: [String.t()], winning_formats: [String.t()], effective_hooks: [String.t()]}}`.

  When the adapter is not configured the job discards immediately (no retries,
  no synthetic output). Real model wiring is deferred to the provider-wiring
  phase; see `BUILDPLAN.md` Phase 11.
  """
  use Oban.Worker, queue: :competitor, max_attempts: 3

  require Logger

  alias ContentForge.Products

  @top_posts_limit 10

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"product_id" => product_id}}) do
    case intel_model() do
      nil ->
        Logger.info(
          "CompetitorIntelSynthesizer skipped for product #{product_id}: intel_model not configured"
        )

        {:discard, :intel_model_not_configured}

      adapter ->
        synthesize_for_product(product_id, adapter)
    end
  end

  defp synthesize_for_product(product_id, adapter) do
    Logger.info("Starting competitor intel synthesis for product #{product_id}")

    with {:ok, _product} <- fetch_product(product_id),
         {:ok, top_posts} <- fetch_top_posts(product_id),
         {:ok, analysis} <- summarize(adapter, top_posts, product_id) do
      store_intel(product_id, top_posts, analysis)
      Logger.info("Competitor intel synthesis completed for product #{product_id}")
      :ok
    else
      :skipped ->
        :ok

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
    {:ok, Products.list_top_competitor_posts_for_product(product_id, @top_posts_limit)}
  end

  defp summarize(_adapter, [], product_id) do
    Logger.info("No competitor posts to analyze for product #{product_id}")
    :skipped
  end

  defp summarize(adapter, posts, _product_id) do
    adapter.summarize(posts)
  end

  defp store_intel(product_id, posts, analysis) do
    Products.create_competitor_intel(%{
      product_id: product_id,
      summary: analysis.summary,
      source_count: length(posts),
      trending_topics: analysis.trending_topics,
      winning_formats: analysis.winning_formats,
      effective_hooks: analysis.effective_hooks
    })
  end

  defp intel_model, do: Application.get_env(:content_forge, :intel_model)
end
