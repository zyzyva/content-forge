defmodule ContentForge.Jobs.CompetitorScraperTest do
  use ContentForge.DataCase, async: false

  use Oban.Testing, repo: ContentForge.Repo

  import ExUnit.CaptureLog

  alias ContentForge.Jobs.CompetitorScraper
  alias ContentForge.Products

  defmodule StubAdapter do
    @moduledoc false
    def fetch_posts(_account) do
      {:ok,
       [
         %{
           post_id: "p1",
           content: "first post",
           post_url: "https://example.com/1",
           likes_count: 100,
           comments_count: 10,
           shares_count: 5,
           posted_at: DateTime.utc_now()
         },
         %{
           post_id: "p2",
           content: "second post",
           post_url: "https://example.com/2",
           likes_count: 10,
           comments_count: 1,
           shares_count: 0,
           posted_at: DateTime.utc_now()
         }
       ]}
    end
  end

  defmodule ErrorAdapter do
    @moduledoc false
    def fetch_posts(_account), do: {:error, :upstream_failure}
  end

  setup do
    original_token = Application.get_env(:content_forge, :apify_token)
    original_adapter = Application.get_env(:content_forge, :scraper_adapter)

    on_exit(fn ->
      restore(:apify_token, original_token)
      restore(:scraper_adapter, original_adapter)
    end)

    {:ok, product} =
      Products.create_product(%{name: "Test Product", voice_profile: "professional"})

    %{product: product}
  end

  defp restore(key, nil), do: Application.delete_env(:content_forge, key)
  defp restore(key, value), do: Application.put_env(:content_forge, key, value)

  describe "perform/1 gating" do
    test "discards when apify_token is not configured", %{product: product} do
      Application.delete_env(:content_forge, :apify_token)
      Application.put_env(:content_forge, :scraper_adapter, StubAdapter)

      assert {:discard, :apify_not_configured} =
               perform_job(CompetitorScraper, %{"product_id" => product.id})
    end

    test "discards when scraper_adapter is not configured", %{product: product} do
      Application.put_env(:content_forge, :apify_token, "test-token")
      Application.delete_env(:content_forge, :scraper_adapter)

      assert {:discard, :scraper_adapter_not_configured} =
               perform_job(CompetitorScraper, %{"product_id" => product.id})
    end
  end

  describe "perform/1 with adapter wired" do
    setup do
      Application.put_env(:content_forge, :apify_token, "test-token")
      Application.put_env(:content_forge, :scraper_adapter, StubAdapter)
      :ok
    end

    test "returns :ok and does nothing when no active competitors exist", %{product: product} do
      assert :ok = perform_job(CompetitorScraper, %{"product_id" => product.id})
      assert Products.list_competitor_accounts_for_product(product.id) == []
    end

    test "stores scored posts for each active competitor account", %{product: product} do
      {:ok, account} =
        Products.create_competitor_account(%{
          product_id: product.id,
          platform: "twitter",
          handle: "acme",
          url: "https://twitter.com/acme",
          active: true
        })

      assert :ok = perform_job(CompetitorScraper, %{"product_id" => product.id})

      posts = Products.list_competitor_posts_for_account(account.id)
      assert length(posts) == 2
      high_engagement = Enum.find(posts, &(&1.post_id == "p1"))
      low_engagement = Enum.find(posts, &(&1.post_id == "p2"))
      assert high_engagement.engagement_score > low_engagement.engagement_score
    end

    test "does not call adapter for inactive accounts", %{product: product} do
      {:ok, _inactive} =
        Products.create_competitor_account(%{
          product_id: product.id,
          platform: "twitter",
          handle: "inactive",
          url: "https://twitter.com/inactive",
          active: false
        })

      assert :ok = perform_job(CompetitorScraper, %{"product_id" => product.id})
      assert Products.list_active_competitor_accounts_for_product(product.id) == []
    end
  end

  describe "perform/1 when storage fails" do
    defmodule InvalidAdapter do
      @moduledoc false
      def fetch_posts(_account) do
        valid_post = %{
          post_id: "ok-1",
          content: "valid post",
          post_url: "https://example.com/1",
          likes_count: 5,
          comments_count: 1,
          shares_count: 0,
          posted_at: DateTime.utc_now()
        }

        invalid_post = %{
          post_id: "bad-1",
          content: nil,
          post_url: "https://example.com/2",
          likes_count: 5,
          comments_count: 1,
          shares_count: 0,
          posted_at: DateTime.utc_now()
        }

        {:ok, [valid_post, invalid_post]}
      end
    end

    test "logs each persistence failure and counts only stored posts", %{product: product} do
      Application.put_env(:content_forge, :apify_token, "test-token")
      Application.put_env(:content_forge, :scraper_adapter, InvalidAdapter)

      {:ok, account} =
        Products.create_competitor_account(%{
          product_id: product.id,
          platform: "twitter",
          handle: "dup",
          url: "https://twitter.com/dup",
          active: true
        })

      log =
        capture_log(fn ->
          assert :ok = perform_job(CompetitorScraper, %{"product_id" => product.id})
        end)

      assert log =~ "Failed to store post"
      stored = Products.list_competitor_posts_for_account(account.id)
      assert length(stored) == 1
    end
  end

  describe "perform/1 when adapter errors" do
    setup do
      Application.put_env(:content_forge, :apify_token, "test-token")
      Application.put_env(:content_forge, :scraper_adapter, ErrorAdapter)
      :ok
    end

    test "still returns :ok but records zero successful scrapes", %{product: product} do
      {:ok, account} =
        Products.create_competitor_account(%{
          product_id: product.id,
          platform: "twitter",
          handle: "broken",
          url: "https://twitter.com/broken",
          active: true
        })

      log =
        capture_log(fn ->
          assert :ok = perform_job(CompetitorScraper, %{"product_id" => product.id})
        end)

      assert log =~ "Failed to scrape broken"
      assert Products.list_competitor_posts_for_account(account.id) == []
    end
  end
end
