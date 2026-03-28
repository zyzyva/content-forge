defmodule ContentForge.ContentGeneration do
  @moduledoc """
  The ContentGeneration context handles content briefs, version history,
  draft management, and multi-model scoring for the AI generation pipeline.
  """
  import Ecto.Query
  alias ContentForge.Repo

  alias ContentForge.Products.ContentBrief
  alias ContentForge.Products.BriefVersion
  alias ContentForge.ContentGeneration.Draft
  alias ContentForge.ContentGeneration.DraftScore

  # ContentBrief CRUD

  def list_content_briefs do
    Repo.all(ContentBrief)
  end

  def list_content_briefs_for_product(product_id) do
    ContentBrief
    |> where(product_id: ^product_id)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def get_content_brief!(id), do: Repo.get!(ContentBrief, id)

  def get_content_brief(id), do: Repo.get(ContentBrief, id)

  def get_latest_content_brief_for_product(product_id) do
    ContentBrief
    |> where(product_id: ^product_id)
    |> order_by(desc: :version)
    |> limit(1)
    |> Repo.one()
  end

  def create_content_brief(attrs \\ %{}) do
    %ContentBrief{}
    |> ContentBrief.changeset(attrs)
    |> Repo.insert()
  end

  def update_content_brief(%ContentBrief{} = brief, attrs) do
    brief
    |> ContentBrief.changeset(attrs)
    |> Repo.update()
  end

  def delete_content_brief(%ContentBrief{} = brief) do
    Repo.delete(brief)
  end

  # BriefVersion CRUD

  def list_brief_versions_for_brief(brief_id) do
    BriefVersion
    |> where(content_brief_id: ^brief_id)
    |> order_by(desc: :version)
    |> Repo.all()
  end

  def get_brief_version!(id), do: Repo.get!(BriefVersion, id)

  def create_brief_version(attrs \\ %{}) do
    %BriefVersion{}
    |> BriefVersion.changeset(attrs)
    |> Repo.insert()
  end

  # Creates a new version of a brief, archiving the old one
  def create_new_brief_version(
        %ContentBrief{} = brief,
        new_content,
        performance_summary \\ %{},
        rewrite_reason \\ nil
      ) do
    Repo.transaction(fn ->
      # Archive current version; treat nil as 1 so archive version is always valid (> 0)
      current_version = brief.version || 1

      # Create historical version record
      %BriefVersion{}
      |> BriefVersion.changeset(%{
        content_brief_id: brief.id,
        version: current_version,
        content: brief.content,
        performance_summary: brief.performance_summary,
        rewrite_reason: rewrite_reason
      })
      |> Repo.insert!()

      # Update brief with new version
      new_version = current_version + 1

      {:ok, updated_brief} =
        brief
        |> ContentBrief.changeset(%{
          content: new_content,
          version: new_version,
          performance_summary: performance_summary
        })
        |> Repo.update()

      updated_brief
    end)
  end

  # Draft CRUD

  def list_drafts do
    Repo.all(Draft)
  end

  def list_drafts_for_product(product_id) do
    Draft
    |> where(product_id: ^product_id)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def list_drafts_by_status(product_id, status) do
    Draft
    |> where(product_id: ^product_id, status: ^status)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def list_drafts_by_type(product_id, content_type) do
    Draft
    |> where(product_id: ^product_id, content_type: ^content_type)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def list_drafts_by_platform(product_id, platform) do
    Draft
    |> where(product_id: ^product_id, platform: ^platform)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def get_draft!(id), do: Repo.get!(Draft, id)

  def get_draft(id), do: Repo.get(Draft, id)

  def create_draft(attrs \\ %{}) do
    %Draft{}
    |> Draft.changeset(attrs)
    |> Repo.insert()
  end

  def create_drafts(attrs_list) when is_list(attrs_list) do
    Repo.insert_all(Draft, attrs_list, returning: true)
  end

  def update_draft(%Draft{} = draft, attrs) do
    draft
    |> Draft.changeset(attrs)
    |> Repo.update()
  end

  def update_draft_status(%Draft{} = draft, status) do
    draft
    |> Draft.changeset(%{status: status})
    |> Repo.update()
  end

  def delete_draft(%Draft{} = draft) do
    Repo.delete(draft)
  end

  def mark_draft_approved(%Draft{} = draft) do
    update_draft_status(draft, "approved")
  end

  def mark_draft_rejected(%Draft{} = draft, _reason \\ nil) do
    draft
    |> Draft.changeset(%{status: "rejected"})
    |> Repo.update()
  end

  # Ranked drafts for a product (passed 3c ranking)
  def list_ranked_drafts(product_id) do
    Draft
    |> where(product_id: ^product_id, status: "ranked")
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  # Approved drafts ready for scheduling
  def list_approved_drafts(product_id) do
    Draft
    |> where(product_id: ^product_id, status: "approved")
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  # Get top N drafts by composite score per type
  def list_top_drafts_by_type(product_id, content_type, limit \\ 3) do
    from(d in Draft,
      where:
        d.product_id == ^product_id and d.content_type == ^content_type and d.status == "ranked",
      order_by: [
        desc:
          fragment(
            "SELECT composite_score FROM draft_scores WHERE draft_id = ? ORDER BY composite_score DESC LIMIT 1",
            d.id
          )
      ],
      limit: ^limit
    )
    |> Repo.all()
  end

  # DraftScore CRUD

  def get_scores_for_draft(draft_id) do
    DraftScore
    |> where(draft_id: ^draft_id)
    |> Repo.all()
  end

  def get_score_for_draft_by_model(draft_id, model_name) do
    DraftScore
    |> where(draft_id: ^draft_id, model_name: ^model_name)
    |> Repo.one()
  end

  def create_draft_score(attrs \\ %{}) do
    %DraftScore{}
    |> DraftScore.changeset(attrs)
    |> Repo.insert()
  end

  def create_draft_scores(attrs_list) when is_list(attrs_list) do
    Repo.insert_all(DraftScore, attrs_list, returning: true)
  end

  # Compute composite score from all model scores for a draft
  def compute_composite_score(draft_id) do
    scores =
      DraftScore
      |> where(draft_id: ^draft_id)
      |> Repo.all()

    if scores == [] do
      nil
    else
      composite_scores = Enum.map(scores, & &1.composite_score)
      Enum.sum(composite_scores) / length(composite_scores)
    end
  end

  # Get all drafts with scores for ranking
  def drafts_with_scores(product_id, content_type \\ nil) do
    query =
      from d in Draft,
        where: d.product_id == ^product_id,
        preload: [:draft_scores]

    query =
      if content_type do
        from d in query, where: d.content_type == ^content_type
      else
        query
      end

    Repo.all(query)
  end

  # Get winners - drafts marked as winner in scoreboard
  def list_winner_drafts(product_id) do
    # This would be joined with content_scoreboard - placeholder for now
    Draft
    |> where(product_id: ^product_id, status: "published")
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  # Repurposing - create new drafts from a winner
  def create_repurposed_draft(%Draft{} = original, platform, content_type, angle) do
    create_draft(%{
      product_id: original.product_id,
      content_brief_id: original.content_brief_id,
      content: original.content,
      platform: platform,
      content_type: content_type,
      angle: angle,
      generating_model: "repurposing_engine",
      status: "draft",
      repurposed_from_id: original.id
    })
  end

  # Get repurposed variants of a draft
  def list_repurposed_variants(draft_id) do
    Draft
    |> where(repurposed_from_id: ^draft_id)
    |> Repo.all()
  end
end
