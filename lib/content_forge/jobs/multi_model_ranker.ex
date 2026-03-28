defmodule ContentForge.Jobs.MultiModelRanker do
  @moduledoc """
  Oban job that scores drafts using multiple smart models (Claude, Gemini, xAI).

  Each model scores on: accuracy (0-10), SEO relevance (0-10), entertainment/education value (0-10).
  Models receive performance scoreboard and their own calibration data to improve accuracy.

  Composite score is averaged across models. Top N per content type are promoted to review queue.
  """
  use Oban.Worker, queue: :content_generation, max_attempts: 3
  require Logger

  alias ContentForge.ContentGeneration
  alias ContentForge.ContentGeneration.DraftScore

  @models ["claude", "gemini", "xai"]
  @default_top_n 3

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"product_id" => product_id, "content_type" => content_type, "top_n" => top_n}
      }) do
    rank_drafts(product_id, content_type, top_n || @default_top_n)
  end

  def perform(%Oban.Job{args: %{"product_id" => product_id, "content_type" => content_type}}) do
    rank_drafts(product_id, content_type, @default_top_n)
  end

  def perform(%Oban.Job{args: %{"product_id" => product_id}}) do
    # Rank all content types
    rank_drafts(product_id, nil, @default_top_n)
  end

  defp rank_drafts(product_id, content_type, top_n) do
    # Get all draft content types to rank if not specified
    types_to_rank =
      if content_type do
        [content_type]
      else
        ["post", "blog", "video_script"]
      end

    Logger.info(
      "Starting multi-model ranking for product #{product_id}, types: #{inspect(types_to_rank)}"
    )

    # Get performance scoreboard and model calibration data
    # (Would come from Phase 7 when implemented)
    scoreboard_context = build_scoreboard_context(product_id)

    Enum.each(types_to_rank, fn type ->
      rank_drafts_by_type(product_id, type, top_n, scoreboard_context)
    end)

    Logger.info("Multi-model ranking complete for product #{product_id}")
    {:ok, %{ranked: true}}
  end

  defp rank_drafts_by_type(product_id, content_type, top_n, scoreboard_context) do
    # Get all draft records for this content type
    drafts =
      ContentGeneration.list_drafts_by_type(product_id, content_type)
      |> Enum.filter(fn d -> d.status == "draft" end)

    if drafts == [] do
      Logger.info("No drafts to rank for #{content_type}")
      {:ok, []}
    else
      # Score each draft with each model
      Enum.each(drafts, fn draft ->
        score_draft_with_all_models(draft, scoreboard_context)
      end)

      # Calculate composite scores and promote top N
      promote_top_n(drafts, top_n, content_type)
    end
  end

  defp score_draft_with_all_models(draft, scoreboard_context) do
    Enum.each(@models, fn model ->
      # Get this model's calibration data
      calibration = get_model_calibration(draft.product_id, model)

      # Score the draft
      scores = query_model_for_scores(draft, model, calibration, scoreboard_context)

      # Store the scores
      attrs = %{
        draft_id: draft.id,
        model_name: model,
        accuracy_score: scores.accuracy,
        seo_score: scores.seo,
        eev_score: scores.eev,
        composite_score: scores.composite,
        critique: scores.critique
      }

      # Update or create score
      existing_score = ContentGeneration.get_score_for_draft_by_model(draft.id, model)

      if existing_score do
        existing_score
        |> DraftScore.changeset(attrs)
        |> ContentForge.Repo.update!()
      else
        ContentGeneration.create_draft_score(attrs)
      end
    end)
  end

  defp query_model_for_scores(draft, model, calibration, scoreboard_context) do
    # Build the scoring prompt with performance context
    _prompt = build_scoring_prompt(draft, model, calibration, scoreboard_context)

    # In production, this would call the actual model API
    # For now, return simulated scores with calibration adjustment
    base_accuracy = Enum.random(6..9)
    base_seo = Enum.random(5..9)
    base_eev = Enum.random(6..10)

    # Adjust based on calibration if available
    accuracy_adjustment = if calibration, do: calibration.avg_score_delta || 0, else: 0

    accuracy = min(10, max(0, base_accuracy + accuracy_adjustment))
    seo = base_seo
    eev = base_eev

    composite = (accuracy + seo + eev) / 3

    critique = """
    This #{draft.angle} #{draft.content_type} for #{draft.platform} demonstrates
    #{if accuracy > 7, do: "strong alignment with product messaging", else: "some alignment but could improve clarity"}.
    #{if eev > 7, do: "High entertainment/education value that should engage readers.", else: "Could benefit from more engaging presentation."}
    #{if seo > 7, do: "Good SEO fundamentals for discoverability.", else: "Consider adding more relevant keywords."}
    """

    %{
      accuracy: accuracy,
      seo: seo,
      eev: eev,
      composite: composite,
      critique: critique
    }
  end

  defp build_scoring_prompt(draft, model, calibration, scoreboard_context) do
    """
    Score this draft content:

    Draft: #{draft.content}
    Platform: #{draft.platform}
    Content Type: #{draft.content_type}
    Angle: #{draft.angle}

    Model: #{model}
    Your calibration: #{inspect(calibration)}

    Performance context:
    - Top performing angles: #{inspect(scoreboard_context.top_angles)}
    - Top performing formats: #{inspect(scoreboard_context.top_formats)}
    - Average engagement: #{scoreboard_context.avg_engagement}

    Score on:
    - Accuracy (0-10): How well does this align with product/policy?
    - SEO (0-10): How well optimized for discovery?
    - EEV (0-10): Entertainment/Education Value

    Provide scores and a brief critique.
    """
  end

  defp get_model_calibration(_product_id, _model_name) do
    # Placeholder - would query model_calibration table when Phase 7 is done
    %{avg_score_delta: 0, sample_count: 0}
  end

  defp build_scoreboard_context(_product_id) do
    # Placeholder - would query content_scoreboard when Phase 7 is done
    %{
      top_angles: ["educational", "humor"],
      top_formats: ["how_to", "listicle"],
      avg_engagement: 0.0,
      recent_winners: [],
      recent_losers: []
    }
  end

  defp promote_top_n(drafts, top_n, _content_type) do
    # Get composite scores for each draft
    drafts_with_scores =
      Enum.map(drafts, fn draft ->
        composite = ContentGeneration.compute_composite_score(draft.id)
        {draft, composite || 0}
      end)
      |> Enum.sort_by(fn {_draft, score} -> score end, :desc)
      |> Enum.take(top_n)

    # Promote top N to ranked status
    Enum.each(drafts_with_scores, fn {draft, score} ->
      ContentGeneration.update_draft_status(draft, "ranked")
      Logger.info("Promoted draft #{draft.id} to ranked (score: #{score})")
    end)

    # Archive the rest (if they were previously ranked, otherwise leave as draft)
    Enum.each(drafts, fn draft ->
      unless Enum.any?(drafts_with_scores, fn {d, _} -> d.id == draft.id end) do
        if draft.status == "ranked" do
          ContentGeneration.update_draft_status(draft, "archived")
        end
      end
    end)

    {:ok, length(drafts_with_scores)}
  end
end
