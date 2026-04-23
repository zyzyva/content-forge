defmodule ContentForge.ContentGeneration.ResearchEnricherTest do
  @moduledoc """
  Coverage for `ContentForge.ContentGeneration.ResearchEnricher`,
  the Phase 12.3 post-generation hook that injects an Original
  Research block into blog drafts.

  The LLM call is stubbed via a configurable adapter
  (`:content_forge, :research_enricher_llm` Application env key)
  so tests can assert hallucination guards without invoking
  Anthropic.
  """
  use ContentForge.DataCase, async: false

  alias ContentForge.ContentGeneration
  alias ContentForge.ContentGeneration.Draft
  alias ContentForge.ContentGeneration.ResearchEnricher
  alias ContentForge.Metrics
  alias ContentForge.Products

  @blog_content """
  # Stripe Checkout Fees Guide

  Body paragraph one.

  Body paragraph two.
  """

  setup do
    {:ok, product} =
      Products.create_product(%{name: "Research Product", voice_profile: "professional"})

    on_exit(fn ->
      Application.delete_env(:content_forge, :research_enricher_llm)
    end)

    %{product: product}
  end

  describe "enrich/1 - ScoreboardEntry source (first priority)" do
    test "writes an enriched block citing the scoreboard data point verbatim",
         %{product: product} do
      draft = insert_blog_draft(product)
      data_point = "2.5 points above average engagement on twitter"

      # Pass delta directly without composite/actual so the
      # changeset's calculate_delta branch leaves our delta alone.
      {:ok, _} =
        Metrics.create_scoreboard_entry(%{
          product_id: product.id,
          content_id: Ecto.UUID.generate(),
          platform: "twitter",
          delta: 2.5,
          outcome: "winner",
          measured_at: DateTime.utc_now()
        })

      stub_llm(fn ->
        {:ok,
         %{
           text:
             "Internal scoreboard data shows #{data_point}. This confirms the angle is resonating.",
           model: "claude-stub"
         }}
      end)

      assert {:ok, %Draft{} = updated} = ResearchEnricher.enrich(draft)
      assert updated.research_status == "enriched"
      assert updated.research_source == "scoreboard"
      assert updated.content =~ data_point
      assert updated.content =~ "Original Research"
    end
  end

  describe "enrich/1 - CompetitorIntel source (second priority)" do
    test "falls through to competitor intel when no scoreboard data is available",
         %{product: product} do
      draft = insert_blog_draft(product)
      topic = "Stripe Checkout v3 rollout timing"

      {:ok, _intel} =
        Products.create_competitor_intel(%{
          product_id: product.id,
          summary: "Competitors leaned into Stripe Checkout migrations this week.",
          source_count: 4,
          trending_topics: [topic, "alternate topic"],
          winning_formats: ["thread"],
          effective_hooks: ["ask first"]
        })

      stub_llm(fn ->
        {:ok,
         %{
           text:
             "Competitor scans surface #{topic} as a trending topic. We cover it in detail below.",
           model: "claude-stub"
         }}
      end)

      assert {:ok, %Draft{} = updated} = ResearchEnricher.enrich(draft)
      assert updated.research_status == "enriched"
      assert updated.research_source == "competitor_intel"
      assert updated.content =~ topic
    end
  end

  describe "enrich/1 - ProductSnapshot source (third priority)" do
    test "falls through to product snapshot when scoreboard and competitor intel are empty",
         %{product: product} do
      draft = insert_blog_draft(product)
      summary = "Stripe documentation cites a 99.999% uptime SLA across all regions."

      {:ok, _snapshot} =
        Products.create_product_snapshot(%{
          product_id: product.id,
          snapshot_type: "site",
          r2_keys: %{"index" => "snapshots/index.txt"},
          token_count: 4200,
          content_summary: summary
        })

      stub_llm(fn ->
        {:ok,
         %{
           text:
             "Per our own documentation crawl: #{summary} That matches what customers rely on.",
           model: "claude-stub"
         }}
      end)

      assert {:ok, %Draft{} = updated} = ResearchEnricher.enrich(draft)
      assert updated.research_status == "enriched"
      assert updated.research_source == "product_snapshot"
      assert updated.content =~ summary
    end
  end

  describe "enrich/1 - hallucination guard" do
    test "flips draft to needs_review when the LLM response drops the data point",
         %{product: product} do
      draft = insert_blog_draft(product)

      # Pass delta directly without composite/actual so the
      # changeset's calculate_delta branch leaves our delta alone.
      {:ok, _} =
        Metrics.create_scoreboard_entry(%{
          product_id: product.id,
          content_id: Ecto.UUID.generate(),
          platform: "twitter",
          delta: 2.5,
          outcome: "winner",
          measured_at: DateTime.utc_now()
        })

      stub_llm(fn ->
        # Deliberately drops the "12.5 points" data.
        {:ok, %{text: "Some vague insight about engagement trends.", model: "claude-stub"}}
      end)

      assert {:error, :lost_data_point, %Draft{} = updated} = ResearchEnricher.enrich(draft)
      assert updated.research_status == "lost_data_point"
      assert updated.status == "needs_review"
      assert updated.error =~ "lost_data_point"
      # Content is NOT mutated on hallucination.
      refute updated.content =~ "Original Research"
    end
  end

  describe "enrich/1 - no data available" do
    test "marks research_status=no_data without calling the LLM",
         %{product: product} do
      draft = insert_blog_draft(product)

      stub_llm(fn -> flunk("LLM should not be called when no data point is available") end)

      assert {:ok, :no_data, %Draft{} = updated} = ResearchEnricher.enrich(draft)
      assert updated.research_status == "no_data"
      assert updated.research_source == nil
    end
  end

  describe "enrich/1 - LLM not configured" do
    test "returns :not_configured without writing when the LLM adapter is unavailable",
         %{product: product} do
      # Stub MUST land before we insert the draft, so the initial
      # create_draft hook also sees the :not_configured branch and
      # doesn't record a no_data / lost_data_point state that
      # would confuse the post-call assertion.
      stub_llm_status(:not_configured)

      draft = insert_blog_draft(product)

      {:ok, _} =
        Metrics.create_scoreboard_entry(%{
          product_id: product.id,
          content_id: Ecto.UUID.generate(),
          platform: "twitter",
          delta: 2.5,
          outcome: "winner",
          measured_at: DateTime.utc_now()
        })

      assert {:error, :not_configured} = ResearchEnricher.enrich(draft)

      reloaded = ContentGeneration.get_draft!(draft.id)
      assert reloaded.research_status == "none"
      refute reloaded.content =~ "Original Research"
    end
  end

  describe "enrich/1 - non-blog drafts pass through" do
    test "returns the draft unchanged for non-blog content_type", %{product: product} do
      {:ok, draft} =
        ContentGeneration.create_draft(%{
          product_id: product.id,
          content: "tweet body",
          platform: "twitter",
          content_type: "post",
          generating_model: "test"
        })

      assert {:ok, ^draft} = ResearchEnricher.enrich(draft)
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp insert_blog_draft(product) do
    {:ok, draft} =
      ContentGeneration.create_draft(%{
        "product_id" => product.id,
        "content" => @blog_content,
        "platform" => "blog",
        "content_type" => "blog",
        "generating_model" => "test"
      })

    draft
  end

  defp stub_llm(fun) do
    Application.put_env(
      :content_forge,
      :research_enricher_llm,
      {__MODULE__.StubLLM, [status: :ok, response_fun: fun]}
    )
  end

  defp stub_llm_status(status) do
    Application.put_env(
      :content_forge,
      :research_enricher_llm,
      {__MODULE__.StubLLM, [status: status, response_fun: fn -> flunk("not called") end]}
    )
  end

  defmodule StubLLM do
    @moduledoc false
    def status(opts), do: Keyword.fetch!(opts, :status)

    def complete(_prompt, _extra_opts, opts) do
      Keyword.fetch!(opts, :response_fun).()
    end
  end
end
