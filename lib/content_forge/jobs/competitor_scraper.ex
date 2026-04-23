defmodule ContentForge.Jobs.CompetitorScraper do
  @moduledoc """
  Oban job that scrapes recent posts from competitor accounts via Apify,
  scores posts by engagement relative to account average, and stores raw data.

  Gated behind two pieces of configuration:

    * `:apify_token` — Apify API token.
    * `:scraper_adapter` — module implementing `fetch_posts/1` per platform.

  When either is missing the job is discarded (no retries, no synthetic
  output). Real adapter implementations land in Phase 11; see `BUILDPLAN.md`.
  """
  use Oban.Worker, queue: :competitor, max_attempts: 3

  require Logger

  alias ContentForge.Products
  alias ContentForge.Products.CompetitorAccount

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"product_id" => product_id}}) do
    case {apify_token(), scraper_adapter()} do
      {nil, _} ->
        Logger.info(
          "CompetitorScraper skipped for product #{product_id}: apify_token not configured"
        )

        {:discard, :apify_not_configured}

      {_token, nil} ->
        Logger.info(
          "CompetitorScraper skipped for product #{product_id}: scraper_adapter not configured"
        )

        {:discard, :scraper_adapter_not_configured}

      {_token, adapter} ->
        scrape_for_product(product_id, adapter)
    end
  end

  defp scrape_for_product(product_id, adapter) do
    Logger.info("Starting competitor scraping for product #{product_id}")

    accounts = Products.list_active_competitor_accounts_for_product(product_id)

    case accounts do
      [] ->
        Logger.info("No active competitor accounts for product #{product_id}")
        :ok

      _ ->
        results = Enum.map(accounts, &scrape_account(&1, adapter))
        successful = Enum.count(results, &produced_data?/1)

        Logger.info(
          "Competitor scraping completed for product #{product_id}, scraped #{successful} accounts"
        )

        if successful > 0, do: schedule_intel_synthesis(product_id)

        :ok
    end
  end

  defp produced_data?({:ok, _}), do: true
  defp produced_data?({:partial, _, _}), do: true
  defp produced_data?(_), do: false

  defp scrape_account(%CompetitorAccount{} = account, adapter) do
    Logger.info("Scraping #{account.platform} account: #{account.handle}")

    case adapter.fetch_posts(account) do
      {:ok, posts} ->
        avg_engagement = calculate_average_engagement(posts)

        {stored, failed} =
          Enum.reduce(posts, {0, 0}, fn post, {ok_count, fail_count} ->
            score = calculate_relative_score(post, avg_engagement)

            case store_post(account, post, score) do
              {:ok, _} ->
                {ok_count + 1, fail_count}

              {:error, changeset} ->
                Logger.error(
                  "Failed to store post #{inspect(post.post_id)} for #{account.handle}: #{inspect(changeset.errors)}"
                )

                {ok_count, fail_count + 1}
            end
          end)

        case failed do
          0 -> {:ok, stored}
          _ -> {:partial, stored, failed}
        end

      {:error, reason} ->
        Logger.error("Failed to scrape #{account.handle}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp calculate_average_engagement([]), do: 0

  defp calculate_average_engagement(posts) do
    total =
      Enum.reduce(posts, 0, fn post, acc ->
        acc + (post.likes_count || 0) + (post.comments_count || 0) * 2 +
          (post.shares_count || 0) * 3
      end)

    total / length(posts)
  end

  defp calculate_relative_score(post, avg_engagement) when avg_engagement > 0 do
    post_engagement =
      (post.likes_count || 0) + (post.comments_count || 0) * 2 + (post.shares_count || 0) * 3

    post_engagement / avg_engagement
  end

  defp calculate_relative_score(_post, _avg_engagement), do: 1.0

  defp store_post(account, post, score) do
    Products.create_competitor_post(%{
      competitor_account_id: account.id,
      post_id: post.post_id,
      content: post.content,
      post_url: post.post_url,
      likes_count: post.likes_count,
      comments_count: post.comments_count,
      shares_count: post.shares_count,
      engagement_score: score,
      posted_at: post.posted_at,
      raw_data: post
    })
  end

  defp schedule_intel_synthesis(product_id) do
    %{"product_id" => product_id}
    |> ContentForge.Jobs.CompetitorIntelSynthesizer.new(
      scheduled_at: DateTime.add(DateTime.utc_now(), 5, :second)
    )
    |> Oban.insert()
  end

  defp apify_token, do: Application.get_env(:content_forge, :apify_token)
  defp scraper_adapter, do: Application.get_env(:content_forge, :scraper_adapter)
end
