defmodule ContentForge.Jobs.MetricsPollerTest do
  use ContentForge.DataCase, async: false
  use Oban.Testing, repo: ContentForge.Repo

  import ExUnit.CaptureLog

  alias ContentForge.ContentGeneration
  alias ContentForge.Jobs.ContentBriefGenerator
  alias ContentForge.Jobs.MetricsPoller
  alias ContentForge.Jobs.WinnerRepurposingEngine
  alias ContentForge.Metrics.ScoreboardEntry
  alias ContentForge.Products

  defp create_product! do
    {:ok, product} =
      Products.create_product(%{name: "Test Product", voice_profile: "professional"})

    product
  end

  defp create_draft!(product, attrs) do
    defaults = %{
      product_id: product.id,
      content: "test draft",
      platform: "twitter",
      content_type: "post",
      angle: "educational",
      generating_model: "claude",
      status: "published"
    }

    {:ok, draft} = ContentGeneration.create_draft(Map.merge(defaults, attrs))
    draft
  end

  defp insert_poor_entry!(product, platform, draft_id, days_ago \\ 1) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    measured_at = DateTime.add(now, -days_ago * 24 * 3600, :second)

    # Insert as a struct to bypass the changeset's auto delta calculation
    Repo.insert!(%ScoreboardEntry{
      content_id: draft_id,
      draft_id: draft_id,
      product_id: product.id,
      platform: platform,
      angle: "educational",
      format: "post",
      composite_ai_score: 7.0,
      actual_engagement_score: 2.5,
      delta: -1.5,
      outcome: "loser",
      measured_at: measured_at,
      inserted_at: now,
      updated_at: now
    })
  end

  describe "check_rewrite_trigger/1" do
    test "enqueues ContentBriefGenerator with force_rewrite when five poor-performer entries exist" do
      product = create_product!()

      for _i <- 1..5 do
        draft = create_draft!(product, %{})
        insert_poor_entry!(product, "twitter", draft.id)
      end

      capture_log(fn -> MetricsPoller.check_rewrite_trigger(product) end)

      assert_enqueued(
        worker: ContentBriefGenerator,
        args: %{"product_id" => product.id, "force_rewrite" => true}
      )
    end

    test "does not enqueue when fewer than five poor-performer entries exist" do
      product = create_product!()

      for _i <- 1..4 do
        draft = create_draft!(product, %{})
        insert_poor_entry!(product, "twitter", draft.id)
      end

      capture_log(fn -> MetricsPoller.check_rewrite_trigger(product) end)

      refute_enqueued(worker: ContentBriefGenerator, args: %{"product_id" => product.id})
    end

    test "is idempotent across repeat calls for the same product" do
      product = create_product!()

      for _i <- 1..5 do
        draft = create_draft!(product, %{})
        insert_poor_entry!(product, "twitter", draft.id)
      end

      capture_log(fn -> MetricsPoller.check_rewrite_trigger(product) end)
      capture_log(fn -> MetricsPoller.check_rewrite_trigger(product) end)

      enqueued =
        all_enqueued(worker: ContentBriefGenerator)
        |> Enum.filter(fn job -> job.args["product_id"] == product.id end)

      assert length(enqueued) == 1
    end

    test "fires per platform when multiple platforms each have five poor performers" do
      product = create_product!()

      for _i <- 1..5 do
        draft = create_draft!(product, %{platform: "twitter"})
        insert_poor_entry!(product, "twitter", draft.id)
      end

      for _i <- 1..5 do
        draft = create_draft!(product, %{platform: "linkedin"})
        insert_poor_entry!(product, "linkedin", draft.id)
      end

      capture_log(fn -> MetricsPoller.check_rewrite_trigger(product) end)

      enqueued =
        all_enqueued(worker: ContentBriefGenerator)
        |> Enum.filter(fn job -> job.args["product_id"] == product.id end)

      # Even though two platforms qualify, args dedup means only one rewrite
      # is enqueued for this product - Oban unique constraint collapses them.
      assert length(enqueued) == 1
    end
  end

  describe "maybe_trigger_spike/2" do
    test "winner with delta above 3.0 enqueues WinnerRepurposingEngine" do
      product = create_product!()
      draft = create_draft!(product, %{})

      entry = %ScoreboardEntry{
        draft_id: draft.id,
        product_id: product.id,
        platform: "twitter",
        outcome: "winner",
        delta: 3.5
      }

      MetricsPoller.maybe_trigger_spike(product, entry)

      assert_enqueued(
        worker: WinnerRepurposingEngine,
        args: %{"draft_id" => draft.id}
      )
    end

    test "winner with delta at exactly 3.0 does NOT enqueue (threshold is strict)" do
      product = create_product!()
      draft = create_draft!(product, %{})

      entry = %ScoreboardEntry{
        draft_id: draft.id,
        product_id: product.id,
        platform: "twitter",
        outcome: "winner",
        delta: 3.0
      }

      MetricsPoller.maybe_trigger_spike(product, entry)

      refute_enqueued(worker: WinnerRepurposingEngine, args: %{"draft_id" => draft.id})
    end

    test "winner with delta below 3.0 does NOT enqueue" do
      product = create_product!()
      draft = create_draft!(product, %{})

      entry = %ScoreboardEntry{
        draft_id: draft.id,
        product_id: product.id,
        platform: "twitter",
        outcome: "winner",
        delta: 2.5
      }

      MetricsPoller.maybe_trigger_spike(product, entry)

      refute_enqueued(worker: WinnerRepurposingEngine, args: %{"draft_id" => draft.id})
    end

    test "loser outcome with high delta does NOT enqueue" do
      product = create_product!()
      draft = create_draft!(product, %{})

      entry = %ScoreboardEntry{
        draft_id: draft.id,
        product_id: product.id,
        platform: "twitter",
        outcome: "loser",
        delta: 3.5
      }

      MetricsPoller.maybe_trigger_spike(product, entry)

      refute_enqueued(worker: WinnerRepurposingEngine, args: %{"draft_id" => draft.id})
    end

    test "is idempotent across repeat calls for the same draft" do
      product = create_product!()
      draft = create_draft!(product, %{})

      entry = %ScoreboardEntry{
        draft_id: draft.id,
        product_id: product.id,
        platform: "twitter",
        outcome: "winner",
        delta: 4.2
      }

      MetricsPoller.maybe_trigger_spike(product, entry)
      MetricsPoller.maybe_trigger_spike(product, entry)

      enqueued =
        all_enqueued(worker: WinnerRepurposingEngine)
        |> Enum.filter(fn job -> job.args["draft_id"] == draft.id end)

      assert length(enqueued) == 1
    end
  end
end
