defmodule ContentForge.OpenClawTools.CompetitorIntelSummaryTest do
  @moduledoc """
  Phase 16.2 read-only tool: returns the most recent competitor
  intel record for the resolved product so the agent can answer
  "what are competitors doing?".
  """
  use ContentForge.DataCase, async: false

  import Ecto.Query

  alias ContentForge.OpenClawTools.CompetitorIntelSummary
  alias ContentForge.Products
  alias ContentForge.Products.CompetitorIntel
  alias ContentForge.Repo

  setup do
    {:ok, product} =
      Products.create_product(%{name: "Sleuth Co", voice_profile: "warm"})

    %{product: product}
  end

  describe "call/2" do
    test "returns the latest competitor intel row for the product", %{product: product} do
      {:ok, old} =
        Products.create_competitor_intel(%{
          product_id: product.id,
          summary: "old summary",
          trending_topics: ["topic-old"],
          winning_formats: ["format-old"],
          effective_hooks: ["hook-old"],
          source_count: 5
        })

      # Competitor intel rows use :utc_datetime (second precision), so back-date
      # the older row to guarantee ordering in this sub-second test.
      Repo.update!(
        Ecto.Changeset.change(old, inserted_at: DateTime.add(old.inserted_at, -60, :second))
      )

      {:ok, latest} =
        Products.create_competitor_intel(%{
          product_id: product.id,
          summary: "latest synthesis of competitor angles",
          trending_topics: ["short-form video", "cost breakdowns"],
          winning_formats: ["listicle", "case study"],
          effective_hooks: ["before / after", "myth busting"],
          source_count: 42
        })

      assert {:ok, result} =
               CompetitorIntelSummary.call(%{}, %{"product" => product.id})

      assert result.product_id == product.id
      assert result.product_name == "Sleuth Co"
      assert result.summary == latest.summary
      assert result.trending_topics == ["short-form video", "cost breakdowns"]
      assert result.winning_formats == ["listicle", "case study"]
      assert result.effective_hooks == ["before / after", "myth busting"]
      assert result.source_post_count == 42
      assert is_binary(result.generated_at)
    end

    test "source_post_count surfaces the raw DB value even when nil", %{product: product} do
      {:ok, intel} =
        Products.create_competitor_intel(%{
          product_id: product.id,
          summary: "no count",
          trending_topics: [],
          winning_formats: [],
          effective_hooks: []
        })

      # The `source_count` column defaults to 0 at the DB level; older rows
      # backfilled without a value can still be nil. Simulate that shape here.
      Repo.update_all(
        from(c in CompetitorIntel, where: c.id == ^intel.id),
        set: [source_count: nil]
      )

      assert {:ok, %{source_post_count: nil}} =
               CompetitorIntelSummary.call(%{}, %{"product" => product.id})
    end

    test "returns :not_found when no competitor intel row exists yet",
         %{product: product} do
      assert {:error, :not_found} =
               CompetitorIntelSummary.call(%{}, %{"product" => product.id})
    end

    test "returns :missing_product_context when no product and no session" do
      assert {:error, :missing_product_context} =
               CompetitorIntelSummary.call(
                 %{channel: "cli", sender_identity: "cli:ops"},
                 %{}
               )
    end
  end
end
