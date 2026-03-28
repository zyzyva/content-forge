defmodule ContentForgeWeb.DraftJSON do
  alias ContentForge.ContentGeneration.Draft
  alias ContentForge.ContentGeneration.DraftScore

  def index(%{drafts: drafts}) do
    %{data: Enum.map(drafts, &draft/1)}
  end

  def show(%{draft: draft}) do
    %{data: draft_with_scores(draft)}
  end

  def draft(%Draft{} = draft) do
    %{
      id: draft.id,
      product_id: draft.product_id,
      content_brief_id: draft.content_brief_id,
      content: draft.content,
      platform: draft.platform,
      content_type: draft.content_type,
      angle: draft.angle,
      generating_model: draft.generating_model,
      status: draft.status,
      repurposed_from_id: draft.repurposed_from_id,
      image_url: draft.image_url,
      inserted_at: draft.inserted_at,
      updated_at: draft.updated_at
    }
  end

  def draft_with_scores(%Draft{} = draft) do
    Map.merge(draft(draft), %{
      scores: Enum.map(draft.draft_scores || [], &score/1)
    })
  end

  def score(%DraftScore{} = score) do
    %{
      id: score.id,
      model_name: score.model_name,
      accuracy_score: score.accuracy_score,
      seo_score: score.seo_score,
      eev_score: score.eev_score,
      composite_score: score.composite_score,
      critique: score.critique
    }
  end

  def created(%{draft: draft}) do
    %{data: draft(draft), message: "Draft created successfully"}
  end

  def updated(%{draft: draft}) do
    %{data: draft(draft), message: "Draft updated successfully"}
  end

  def approved(%{draft: draft}) do
    %{data: draft(draft), message: "Draft approved for scheduling"}
  end

  def rejected(%{draft: draft}) do
    %{data: draft(draft), message: "Draft rejected"}
  end

  def scored(%{draft: draft, score: score}) do
    %{data: draft_with_scores(draft), score: score(score), message: "Score submitted"}
  end
end