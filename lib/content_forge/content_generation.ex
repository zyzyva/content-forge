defmodule ContentForge.ContentGeneration do
  @moduledoc """
  The ContentGeneration context handles content briefs, version history,
  draft management, and multi-model scoring for the AI generation pipeline.
  """
  import Ecto.Query
  alias ContentForge.Repo

  alias ContentForge.ContentGeneration.Draft
  alias ContentForge.ContentGeneration.DraftAsset
  alias ContentForge.ContentGeneration.DraftScore
  alias ContentForge.ContentGeneration.NuggetValidator
  alias ContentForge.ContentGeneration.ResearchEnricher
  alias ContentForge.ContentGeneration.SeoChecklist
  alias ContentForge.ProductAssets.ProductAsset
  alias ContentForge.Products.BriefVersion
  alias ContentForge.Products.ContentBrief

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
        rewrite_reason \\ nil,
        opts \\ []
      ) do
    model_used = Keyword.get(opts, :model_used)

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

      attrs =
        %{
          content: new_content,
          version: new_version,
          performance_summary: performance_summary
        }
        |> put_if_present(:model_used, model_used)

      {:ok, updated_brief} =
        brief
        |> ContentBrief.changeset(attrs)
        |> Repo.update()

      updated_brief
    end)
  end

  # Draft CRUD

  def list_drafts do
    Repo.all(Draft)
  end

  def count_drafts_for_product(product_id) do
    Draft
    |> where(product_id: ^product_id)
    |> select([d], count(d.id))
    |> Repo.one()
  end

  def list_recent_draft_ids(limit) when is_integer(limit) and limit > 0 do
    Draft
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> select([d], d.id)
    |> Repo.all()
  end

  def list_drafts_for_product(product_id) do
    Draft
    |> where(product_id: ^product_id)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def list_drafts_by_status(nil, status) do
    Draft
    |> where(status: ^status)
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

  def get_draft_by_media_forge_job_id(nil), do: nil

  def get_draft_by_media_forge_job_id(job_id) when is_binary(job_id) do
    Repo.get_by(Draft, media_forge_job_id: job_id)
  end

  def create_draft(attrs \\ %{}) do
    %Draft{}
    |> Draft.changeset(attrs)
    |> Repo.insert()
    |> maybe_validate_nugget()
  end

  # Post-insert hook for the Phase 12.1 AI Summary Nugget.
  # Runs only on blog drafts; non-blog drafts pass through.
  defp maybe_validate_nugget({:ok, %Draft{content_type: "blog"} = draft}) do
    apply_nugget_validation(draft)
  end

  defp maybe_validate_nugget(result), do: result

  defp apply_nugget_validation(%Draft{content: content} = draft) do
    case NuggetValidator.validate(content) do
      {:ok, nugget} ->
        draft
        |> Draft.changeset(%{ai_summary_nugget: nugget})
        |> Repo.update()
        |> maybe_run_seo_checklist()

      {:error, reasons} ->
        # Nugget failure already flags needs_review. Still run the
        # SEO checklist so operators see the full picture in the
        # drawer when they open the draft to fix the nugget.
        draft
        |> Draft.changeset(%{
          status: "needs_review",
          error: NuggetValidator.format_reasons(reasons)
        })
        |> Repo.update()
        |> maybe_run_seo_checklist()
    end
  end

  defp maybe_run_seo_checklist({:ok, %Draft{content_type: "blog"} = draft}) do
    _ = SeoChecklist.Runner.run(draft)
    maybe_enrich_research(draft)
  end

  defp maybe_run_seo_checklist(result), do: result

  # Research enrichment runs AFTER the SEO checklist so the
  # checks see the un-enriched draft shape. The enricher appends
  # an Original Research block without mutating anything the SEO
  # checklist already evaluated. Result shape stays
  # `{:ok, draft}` for blog drafts - enrichment outcomes are
  # visible via `research_status` on the reloaded draft.
  defp maybe_enrich_research(draft) do
    draft = Repo.reload(draft)

    case ResearchEnricher.enrich(draft) do
      {:ok, %Draft{} = updated} -> {:ok, updated}
      {:ok, :no_data, %Draft{} = updated} -> {:ok, updated}
      {:error, :lost_data_point, %Draft{} = updated} -> {:ok, updated}
      {:error, :not_configured} -> {:ok, draft}
      {:error, _reason} -> {:ok, draft}
    end
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

  @doc """
  Phase 12.4 publish gate for blog drafts. Blocks approval when
  `seo_score` is below the configured `:publish_threshold` (see
  `config :content_forge, :seo, publish_threshold:`) OR when
  `research_status == "lost_data_point"`.

  Non-blog drafts bypass the gate and approve normally.

  Returns:

    * `{:ok, draft}` - approved
    * `{:error, :seo_below_threshold, %{score: n, threshold: t, failing_checks: [..]}}`
    * `{:error, :research_lost_data, %{research_source: src}}`
  """
  def approve_blog_draft(draft, opts \\ [])

  def approve_blog_draft(%Draft{content_type: "blog"} = draft, opts) do
    threshold = Keyword.get(opts, :publish_threshold, seo_publish_threshold())
    score = draft.seo_score || 0

    cond do
      draft.research_status == "lost_data_point" ->
        {:error, :research_lost_data, %{research_source: draft.research_source}}

      score < threshold ->
        {:error, :seo_below_threshold,
         %{
           score: score,
           threshold: threshold,
           failing_checks: seo_failing_checks(draft)
         }}

      true ->
        mark_draft_approved(draft)
    end
  end

  def approve_blog_draft(%Draft{} = draft, _opts), do: mark_draft_approved(draft)

  @doc """
  Override path for blog drafts that fail the publish gate.
  Records the override reason + a snapshot of the score and
  research_status AT the moment of approval, then transitions to
  `"approved"`. Requires `reason` to be a string with at least
  20 characters.

  Non-blog drafts still pass through `mark_draft_approved/1` but
  also record the override fields for audit symmetry.
  """
  def approve_blog_draft_with_override(%Draft{} = draft, reason, opts \\ [])
      when is_binary(reason) do
    trimmed = String.trim(reason)

    if String.length(trimmed) < override_min_reason_length() do
      {:error, :override_reason_too_short,
       %{min_length: override_min_reason_length(), got_length: String.length(trimmed)}}
    else
      attrs = %{
        status: "approved",
        approved_via_override: true,
        override_reason: trimmed,
        override_score_at_approval: draft.seo_score || 0,
        override_research_status_at_approval: draft.research_status || "none"
      }

      # Skip-gate flag is honored so the override path is truly
      # out-of-band from the normal approve call stack.
      _ = Keyword.get(opts, :skip_gate, true)

      draft
      |> Draft.changeset(attrs)
      |> Repo.update()
    end
  end

  defp seo_publish_threshold do
    Application.get_env(:content_forge, :seo, [])
    |> Keyword.get(:publish_threshold, 18)
  end

  defp override_min_reason_length, do: 20

  defp seo_failing_checks(%Draft{} = draft) do
    case SeoChecklist.Runner.get_for_draft(draft.id) do
      nil ->
        []

      %SeoChecklist{results: results} ->
        results
        |> Enum.filter(fn {_name, value} -> value["status"] == "fail" end)
        |> Enum.map(fn {name, value} ->
          %{name: name, note: value["note"]}
        end)
        |> Enum.sort_by(& &1.name)
    end
  end

  def mark_draft_rejected(%Draft{} = draft, _reason \\ nil) do
    draft
    |> Draft.changeset(%{status: "rejected"})
    |> Repo.update()
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  def mark_draft_blocked(%Draft{} = draft) do
    draft
    |> Draft.changeset(%{status: "blocked"})
    |> Repo.update()
  end

  # Draft - ProductAsset many-to-many (draft_assets join).
  # `draft.image_url` remains authoritative for publishing in Phase 13.4;
  # Phase 13.5 swaps the publisher over to read from this relation.

  @doc """
  Attaches `asset` to `draft` in the given role (`"featured"` or
  `"gallery"`, default `"featured"`). Duplicate attaches are idempotent
  - returns the existing row without raising the unique-constraint
  error. Accepts either struct or id arguments on both sides.
  """
  @spec attach_asset(
          Draft.t() | Ecto.UUID.t(),
          ProductAsset.t() | Ecto.UUID.t(),
          keyword()
        ) :: {:ok, DraftAsset.t()} | {:error, Ecto.Changeset.t()}
  def attach_asset(draft, asset, opts \\ [])

  def attach_asset(%Draft{id: draft_id}, %ProductAsset{id: asset_id}, opts) do
    role = Keyword.get(opts, :role, "featured")

    case Repo.get_by(DraftAsset, draft_id: draft_id, asset_id: asset_id) do
      %DraftAsset{} = existing ->
        {:ok, existing}

      nil ->
        %DraftAsset{}
        |> DraftAsset.changeset(%{draft_id: draft_id, asset_id: asset_id, role: role})
        |> Repo.insert()
    end
  end

  def attach_asset(draft_id, asset_id, opts) when is_binary(draft_id) and is_binary(asset_id) do
    attach_asset(get_draft!(draft_id), ProductAsset |> Repo.get!(asset_id), opts)
  end

  @doc "Detaches `asset` from `draft`. No-op if the pair is not linked."
  @spec detach_asset(Draft.t(), ProductAsset.t()) :: :ok
  def detach_asset(%Draft{id: draft_id}, %ProductAsset{id: asset_id}) do
    case Repo.get_by(DraftAsset, draft_id: draft_id, asset_id: asset_id) do
      nil -> :ok
      row -> Repo.delete(row) |> discard_result()
    end
  end

  defp discard_result({:ok, _}), do: :ok
  defp discard_result({:error, _} = err), do: err

  @doc """
  Lists the `%ProductAsset{}` rows attached to `draft_id`, in attach
  order (ascending `draft_assets.inserted_at`).
  """
  @spec list_assets_for_draft(Ecto.UUID.t()) :: [ProductAsset.t()]
  def list_assets_for_draft(draft_id) when is_binary(draft_id) do
    from(da in DraftAsset,
      where: da.draft_id == ^draft_id,
      order_by: [asc: da.inserted_at],
      join: a in assoc(da, :asset),
      select: a
    )
    |> Repo.all()
  end

  # Blocked drafts (for example, social posts missing their Stage 3.5 image)
  def list_blocked_drafts(nil) do
    Draft
    |> where(status: "blocked")
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def list_blocked_drafts(product_id) do
    Draft
    |> where(product_id: ^product_id, status: "blocked")
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  # Ranked drafts for a product (passed 3c ranking)
  def list_ranked_drafts(product_id) do
    Draft
    |> where(product_id: ^product_id, status: "ranked")
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  # Approved drafts ready for scheduling
  def list_approved_drafts(nil) do
    Draft
    |> where(status: "approved")
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

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
