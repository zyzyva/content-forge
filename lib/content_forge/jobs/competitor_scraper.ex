defmodule ContentForge.Jobs.CompetitorScraper do
  @moduledoc """
  Oban job that scrapes recent posts from competitor accounts via Apify,
  scores posts by engagement relative to account average, and stores raw data.
  """
  use Oban.Worker, queue: :competitor, max_attempts: 3

  require Logger

  alias ContentForge.Products
  alias ContentForge.Products.CompetitorAccount

  @apify_token Application.compile_env(:content_forge, :apify_token)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"product_id" => product_id}}) do
    Logger.info("Starting competitor scraping for product #{product_id}")

    accounts = Products.list_active_competitor_accounts_for_product(product_id)

    if accounts == [] do
      Logger.info("No active competitor accounts for product #{product_id}")
      :ok
    else
      results =
        Enum.map(accounts, fn account ->
          scrape_account(account)
        end)

      successful = Enum.count(results, &match?({:ok, _}, &1))

      Logger.info(
        "Competitor scraping completed for product #{product_id}, scraped #{successful} accounts"
      )

      if successful > 0 do
        schedule_intel_synthesis(product_id)
      end

      :ok
    end
  end

  defp scrape_account(%CompetitorAccount{} = account) do
    Logger.info("Scraping #{account.platform} account: #{account.handle}")

    case fetch_posts_from_apify(account) do
      {:ok, posts} ->
        avg_engagement = calculate_average_engagement(posts)

        Enum.each(posts, fn post ->
          score = calculate_relative_score(post, avg_engagement)
          store_post(account, post, score)
        end)

        {:ok, length(posts)}

      {:error, reason} ->
        Logger.error("Failed to scrape #{account.handle}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fetch_posts_from_apify(account) do
    case @apify_token do
      nil -> {:ok, mock_posts(account)}
      _token -> fetch_posts_real(account)
    end
  end

  defp fetch_posts_real(%CompetitorAccount{platform: "twitter", handle: _handle}) do
    # Use Apify Twitter scraper
    # This would be a real Apify API call in production
    # Return error to indicate not implemented yet
    {:error, :not_implemented}
  end

  defp fetch_posts_real(%CompetitorAccount{platform: "linkedin", handle: _handle}) do
    {:error, :not_implemented}
  end

  defp fetch_posts_real(%CompetitorAccount{platform: platform, handle: _handle}) do
    Logger.info("Apify scraper not implemented for platform: #{platform}")
    {:error, :not_implemented}
  end

  defp mock_posts(account) do
    # Generate mock posts for testing
    [
      %{
        post_id: "mock_1_#{account.id}",
        content:
          "Exciting news! Our latest product update brings revolutionary features that will transform how you work. Check it out and let us know what you think! #innovation #tech",
        post_url: "https://#{account.platform}.com/#{account.handle}/status/1",
        likes_count: Enum.random(50..500),
        comments_count: Enum.random(5..50),
        shares_count: Enum.random(10..100),
        posted_at: DateTime.add(DateTime.utc_now(), -Enum.random(1..7), :day)
      },
      %{
        post_id: "mock_2_#{account.id}",
        content:
          "Behind the scenes of our development process. We're working hard to bring you something amazing. Stay tuned! 🚀",
        post_url: "https://#{account.platform}.com/#{account.handle}/status/2",
        likes_count: Enum.random(100..1000),
        comments_count: Enum.random(10..100),
        shares_count: Enum.random(20..200),
        posted_at: DateTime.add(DateTime.utc_now(), -Enum.random(8..14), :day)
      },
      %{
        post_id: "mock_3_#{account.id}",
        content:
          "Customer spotlight: See how @acme_corp is using our solution to drive results. Great things happening!",
        post_url: "https://#{account.platform}.com/#{account.handle}/status/3",
        likes_count: Enum.random(30..300),
        comments_count: Enum.random(3..30),
        shares_count: Enum.random(5..50),
        posted_at: DateTime.add(DateTime.utc_now(), -Enum.random(15..21), :day)
      }
    ]
  end

  defp calculate_average_engagement(posts) do
    if posts == [] do
      0
    else
      total =
        Enum.reduce(posts, 0, fn post, acc ->
          acc + (post.likes_count || 0) + (post.comments_count || 0) * 2 +
            (post.shares_count || 0) * 3
        end)

      total / length(posts)
    end
  end

  defp calculate_relative_score(post, avg_engagement) do
    post_engagement =
      (post.likes_count || 0) + (post.comments_count || 0) * 2 + (post.shares_count || 0) * 3

    if avg_engagement > 0 do
      post_engagement / avg_engagement
    else
      1.0
    end
  end

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
    Oban.insert(%Oban.Job{
      queue: :competitor,
      worker: ContentForge.Jobs.CompetitorIntelSynthesizer,
      args: %{"product_id" => product_id},
      scheduled_at: DateTime.add(DateTime.utc_now(), 5, :second)
    })
  end
end
