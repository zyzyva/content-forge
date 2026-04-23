defmodule ContentForge.E2E.HappyPathTest do
  @moduledoc """
  End-to-end integration walk: product → brief → variants → rank →
  promote → publish → metrics-spike → repurpose.

  Exercises each worker via `Oban.Testing.perform_job/2` rather than
  waiting for Oban's real dispatcher, so the test is deterministic
  without sleeps.

  The test deliberately does NOT exercise:

    * `OpenClawBulkGenerator` - OpenClaw conversational endpoint is
      still unavailable (see 11.2 caller decision). Variants are
      hand-created instead.
    * Real `Media Forge`, `SMS` paths - those are separate E2E
      slices under 15.3.2+ once their externals have Req.Test seams.
    * The `Publisher` worker's platform-client call - `Twitter` /
      `LinkedIn` clients use raw `Req.get` / `Req.post` without a
      `req_options` seam, so this slice proves the publish state
      transition by writing the `PublishedPost` row + flipping the
      draft to `"published"` directly. Refactoring those clients for
      Req.Test is 15.3.2 territory.

  `MetricsPoller.perform/1` walks through multiple platform metric
  clients which also lack Req.Test seams; this slice calls
  `MetricsPoller.maybe_trigger_spike/2` directly with a seeded
  winning `ScoreboardEntry` - the same code path the full poller
  exercises when it detects a winner.
  """
  use ContentForge.DataCase, async: false
  use Oban.Testing, repo: ContentForge.Repo

  import ExUnit.CaptureLog

  alias ContentForge.ContentGeneration
  alias ContentForge.ContentGeneration.Draft
  alias ContentForge.ContentGeneration.DraftScore
  alias ContentForge.Jobs.ContentBriefGenerator
  alias ContentForge.Jobs.MetricsPoller
  alias ContentForge.Jobs.MultiModelRanker
  alias ContentForge.Jobs.WinnerRepurposingEngine
  alias ContentForge.Metrics.ScoreboardEntry
  alias ContentForge.Products
  alias ContentForge.Publishing
  alias ContentForge.Test.E2EStubs

  setup do
    E2EStubs.setup_llm_stubs()

    {:ok, product} =
      Products.create_product(%{
        name: "E2E Product",
        voice_profile: "professional"
      })

    %{product: product}
  end

  defp stub_llm_scoring do
    # Every scoring request returns a structured JSON body with valid
    # bounded scores. Both providers get the same shape so the
    # MultiModelRanker parses both without fabrication.
    scoring_json =
      JSON.encode!(%{
        "accuracy" => 8.5,
        "seo" => 8.0,
        "eev" => 7.5,
        "critique" => "solid on-voice copy"
      })

    E2EStubs.stub_anthropic_text(scoring_json)
    E2EStubs.stub_gemini_text(scoring_json)
  end

  defp hand_create_variants!(product, count) do
    for i <- 1..count do
      {:ok, draft} =
        ContentGeneration.create_draft(%{
          product_id: product.id,
          content: "Variant #{i} copy on-voice",
          platform: "twitter",
          content_type: "post",
          angle: "educational",
          generating_model: "hand_created_for_e2e",
          status: "draft",
          image_url: "https://cdn.example/variant_#{i}.png"
        })

      draft
    end
  end

  test "full happy path: product -> brief -> variants -> rank -> publish -> metrics -> repurpose",
       %{product: product} do
    capture_log(fn ->
      # =================================================================
      # Stage 1: Content brief generation
      # =================================================================
      # BriefSynthesizer calls both providers when both are
      # configured; it then synthesizes the two replies into a final
      # brief via one more Anthropic call. All three call sites get
      # the stubbed text.
      E2EStubs.stub_anthropic_text("# E2E content brief body")
      E2EStubs.stub_gemini_text("# Gemini contribution to the brief")

      assert {:ok, brief} =
               perform_job(ContentBriefGenerator, %{"product_id" => product.id})

      assert brief.product_id == product.id
      assert brief.version == 1
      assert brief.content == "# E2E content brief body"
      # The actual model string Anthropic returned lands on the brief.
      assert brief.model_used =~ "anthropic"

      # No synthetic placeholders: the brief content is exactly what the
      # LLM returned, and zero other ContentBrief rows exist.
      assert length(ContentGeneration.list_content_briefs_for_product(product.id)) == 1

      # =================================================================
      # Stage 2: Variants (OpenClaw skipped per spec)
      # =================================================================
      variants = hand_create_variants!(product, 3)
      assert length(variants) == 3
      assert Enum.all?(variants, &(&1.status == "draft"))

      # =================================================================
      # Stage 3: Multi-model ranking
      # =================================================================
      stub_llm_scoring()

      assert {:ok, _} =
               perform_job(MultiModelRanker, %{
                 "product_id" => product.id,
                 "content_type" => "post"
               })

      # DraftScore rows exist for every (draft, model) pair with the
      # stubbed scores. No synthetic fills when JSON was valid.
      scores = Repo.all(DraftScore)
      assert length(scores) == 6
      assert Enum.all?(scores, &(&1.accuracy_score == 8.5))

      # Top drafts were promoted to "ranked" (default top_n is 3 and we
      # have exactly 3 variants, so all promote).
      ranked =
        ContentGeneration.list_drafts_for_product(product.id)
        |> Enum.filter(&(&1.status == "ranked"))

      assert length(ranked) == 3

      # =================================================================
      # Stage 4: Promote + publish
      # =================================================================
      winner = hd(ranked)
      {:ok, winner} = ContentGeneration.mark_draft_approved(winner)
      assert winner.status == "approved"

      # Publisher's platform clients lack Req.Test seams - write the
      # PublishedPost row directly to prove the state transition.
      {:ok, published_post} =
        Publishing.create_published_post(%{
          product_id: product.id,
          draft_id: winner.id,
          platform: winner.platform,
          platform_post_id: "tw_e2e_1",
          platform_post_url: "https://twitter.com/i/status/tw_e2e_1",
          posted_at: DateTime.utc_now()
        })

      {:ok, _} = ContentGeneration.update_draft_status(winner, "published")

      assert ContentGeneration.get_draft!(winner.id).status == "published"
      assert published_post.draft_id == winner.id
      assert length(Publishing.list_published_posts(product_id: product.id)) == 1

      # =================================================================
      # Stage 5: Metrics -> winning ScoreboardEntry -> repurpose
      # =================================================================
      # Seed a scoreboard entry whose delta is in winning territory
      # (>3.0 against composite 8.5). `maybe_trigger_spike/2` is the
      # exact path `MetricsPoller.perform/1` invokes when it detects
      # a winner.
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      winning_entry =
        Repo.insert!(%ScoreboardEntry{
          content_id: winner.id,
          draft_id: winner.id,
          product_id: product.id,
          platform: "twitter",
          angle: winner.angle,
          format: "post",
          composite_ai_score: 8.5,
          actual_engagement_score: 12.0,
          delta: 3.5,
          outcome: "winner",
          measured_at: now,
          inserted_at: now,
          updated_at: now
        })

      MetricsPoller.maybe_trigger_spike(product, winning_entry)

      assert_enqueued(
        worker: WinnerRepurposingEngine,
        args: %{"draft_id" => winner.id}
      )

      # =================================================================
      # Stage 6: WinnerRepurposingEngine
      # =================================================================
      assert {:ok, %{variants_created: n}} =
               perform_job(WinnerRepurposingEngine, %{"draft_id" => winner.id})

      assert n == 3

      repurposed =
        Repo.all(Draft)
        |> Enum.filter(&(&1.repurposed_from_id == winner.id))

      assert length(repurposed) == 3

      # Cross-platform targets for a twitter/post winner are
      # linkedin/post, reddit/post, blog/blog. Every one carries the
      # repurposing_engine model marker (NOT a fake LLM label).
      platforms = repurposed |> Enum.map(& &1.platform) |> Enum.sort()
      assert platforms == ["blog", "linkedin", "reddit"]
      assert Enum.all?(repurposed, &(&1.generating_model == "repurposing_engine"))
      assert Enum.all?(repurposed, &(&1.status == "draft"))
      assert Enum.all?(repurposed, &(&1.content_brief_id == winner.content_brief_id))
    end)
  end
end
