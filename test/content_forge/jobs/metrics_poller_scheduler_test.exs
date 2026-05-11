defmodule ContentForge.Jobs.MetricsPollerSchedulerTest do
  use ContentForge.DataCase, async: false
  use Oban.Testing, repo: ContentForge.Repo

  import ExUnit.CaptureLog

  alias ContentForge.ContentGeneration
  alias ContentForge.Jobs.MetricsPoller
  alias ContentForge.Jobs.MetricsPollerScheduler
  alias ContentForge.Products
  alias ContentForge.Publishing
  alias ContentForge.Repo

  defp create_product!(name) do
    {:ok, product} = Products.create_product(%{name: name, voice_profile: "professional"})
    product
  end

  defp create_draft!(product) do
    {:ok, draft} =
      ContentGeneration.create_draft(%{
        product_id: product.id,
        platform: "twitter",
        content_type: "post",
        angle: "humor",
        content: "draft body",
        generating_model: "test"
      })

    draft
  end

  defp publish_for!(product, days_ago \\ 1) do
    draft = create_draft!(product)

    {:ok, post} =
      Publishing.create_published_post(%{
        product_id: product.id,
        draft_id: draft.id,
        platform: "twitter",
        platform_post_id: "p-#{System.unique_integer([:positive])}",
        platform_post_url: "https://x.com/x/status/1",
        posted_at: DateTime.utc_now() |> DateTime.add(-days_ago * 24 * 3600, :second)
      })

    post
  end

  describe "active_product_ids/0" do
    test "returns products with a published post in the last 90 days" do
      active = create_product!("Active")
      stale = create_product!("Stale")
      _none = create_product!("Never Published")

      publish_for!(active, 1)
      publish_for!(stale, 200)

      ids = MetricsPollerScheduler.active_product_ids()
      assert active.id in ids
      refute stale.id in ids
    end

    test "returns one entry per product even when many posts exist" do
      product = create_product!("Many Posts")

      for _ <- 1..3, do: publish_for!(product, 1)

      ids = MetricsPollerScheduler.active_product_ids()
      assert Enum.count(ids, &(&1 == product.id)) == 1
    end
  end

  describe "perform/1" do
    test "enqueues one MetricsPoller job per active product" do
      a = create_product!("A")
      b = create_product!("B")
      stale = create_product!("Stale")

      publish_for!(a, 1)
      publish_for!(b, 5)
      publish_for!(stale, 200)

      capture_log(fn -> assert :ok = perform_job(MetricsPollerScheduler, %{}) end)

      assert_enqueued(worker: MetricsPoller, args: %{"product_id" => a.id})
      assert_enqueued(worker: MetricsPoller, args: %{"product_id" => b.id})
      refute_enqueued(worker: MetricsPoller, args: %{"product_id" => stale.id})
    end

    test "is a no-op when no active products exist" do
      _none = create_product!("Quiet")

      capture_log(fn -> assert :ok = perform_job(MetricsPollerScheduler, %{}) end)

      assert all_enqueued(worker: MetricsPoller) == []
    end

    test "repeated runs collapse to one MetricsPoller per product (Oban unique)" do
      product = create_product!("Re-run")
      publish_for!(product, 1)

      capture_log(fn -> assert :ok = perform_job(MetricsPollerScheduler, %{}) end)
      capture_log(fn -> assert :ok = perform_job(MetricsPollerScheduler, %{}) end)

      jobs =
        all_enqueued(worker: MetricsPoller)
        |> Enum.filter(fn job -> job.args["product_id"] == product.id end)

      assert length(jobs) == 1
    end
  end
end
