defmodule ContentForge.Jobs.CompetitorScrapeRefresherTest do
  use ContentForge.DataCase, async: false
  use Oban.Testing, repo: ContentForge.Repo

  import ExUnit.CaptureLog

  alias ContentForge.Jobs.CompetitorScraper
  alias ContentForge.Jobs.CompetitorScrapeRefresher
  alias ContentForge.Products

  defp create_product!(name) do
    {:ok, product} = Products.create_product(%{name: name, voice_profile: "professional"})
    product
  end

  defp create_account!(product, attrs \\ %{}) do
    base = %{
      product_id: product.id,
      platform: "twitter",
      handle: "rival-#{System.unique_integer([:positive])}",
      url: "https://x.com/rival",
      active: true
    }

    {:ok, account} = Products.create_competitor_account(Map.merge(base, attrs))
    account
  end

  describe "product_ids_with_active_competitors/0" do
    test "returns the product ids of products with at least one active competitor" do
      a = create_product!("With Active")
      b = create_product!("Inactive Only")
      _c = create_product!("No Competitors")

      create_account!(a)
      create_account!(b, %{active: false})

      ids = CompetitorScrapeRefresher.product_ids_with_active_competitors()
      assert a.id in ids
      refute b.id in ids
    end

    test "returns each qualifying product exactly once even with multiple competitors" do
      product = create_product!("Many Competitors")
      create_account!(product, %{handle: "one"})
      create_account!(product, %{handle: "two"})
      create_account!(product, %{handle: "three"})

      ids = CompetitorScrapeRefresher.product_ids_with_active_competitors()
      assert Enum.count(ids, &(&1 == product.id)) == 1
    end
  end

  describe "perform/1" do
    test "enqueues one CompetitorScraper per product with active competitors" do
      a = create_product!("A")
      b = create_product!("B")
      none = create_product!("None")
      create_account!(a)
      create_account!(b)
      create_account!(none, %{active: false})

      capture_log(fn -> assert :ok = perform_job(CompetitorScrapeRefresher, %{}) end)

      assert_enqueued(worker: CompetitorScraper, args: %{"product_id" => a.id})
      assert_enqueued(worker: CompetitorScraper, args: %{"product_id" => b.id})
      refute_enqueued(worker: CompetitorScraper, args: %{"product_id" => none.id})
    end

    test "is a no-op when no products have active competitors" do
      _none = create_product!("Quiet")

      capture_log(fn -> assert :ok = perform_job(CompetitorScrapeRefresher, %{}) end)

      assert all_enqueued(worker: CompetitorScraper) == []
    end

    test "repeated runs collapse to one job per product (Oban unique)" do
      product = create_product!("Re-run")
      create_account!(product)

      capture_log(fn -> assert :ok = perform_job(CompetitorScrapeRefresher, %{}) end)
      capture_log(fn -> assert :ok = perform_job(CompetitorScrapeRefresher, %{}) end)

      jobs =
        all_enqueued(worker: CompetitorScraper)
        |> Enum.filter(fn job -> job.args["product_id"] == product.id end)

      assert length(jobs) == 1
    end
  end
end
