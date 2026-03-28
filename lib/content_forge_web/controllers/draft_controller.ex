defmodule ContentForgeWeb.DraftController do
  use ContentForgeWeb, :controller

  alias ContentForge.ContentGeneration
  alias ContentForge.ContentGeneration.Draft
  alias ContentForge.Products

  action_fallback ContentForgeWeb.FallbackController

  # GET /api/v1/products/:product_id/drafts
  def index(conn, %{"product_id" => product_id}) do
    # Parse query params
    status = get_query_param(conn, "status")
    content_type = get_query_param(conn, "content_type")
    platform = get_query_param(conn, "platform")
    min_score = get_query_param(conn, "min_score") |> parse_float()

    drafts =
      cond do
        status ->
          ContentGeneration.list_drafts_by_status(product_id, status)

        content_type ->
          ContentGeneration.list_drafts_by_type(product_id, content_type)

        platform ->
          ContentGeneration.list_drafts_by_platform(product_id, platform)

        true ->
          ContentGeneration.list_drafts_for_product(product_id)
      end

    # Filter by minimum score if specified
    drafts =
      if min_score do
        Enum.filter(drafts, fn draft ->
          score = ContentGeneration.compute_composite_score(draft.id)
          score && score >= min_score
        end)
      else
        drafts
      end

    render(conn, :index, drafts: drafts)
  end

  # GET /api/v1/drafts/:id
  def show(conn, %{"id" => id}) do
    draft = ContentGeneration.get_draft!(id) |> ContentForge.Repo.preload(:draft_scores)
    render(conn, :show, draft: draft)
  end

  # POST /api/v1/products/:product_id/drafts
  def create(conn, %{"product_id" => product_id, "draft" => draft_params}) do
    # Verify product exists
    product = Products.get_product!(product_id)

    attrs = Map.put(draft_params, "product_id", product.id)

    with {:ok, draft} <- ContentGeneration.create_draft(attrs) do
      conn
      |> put_status(:created)
      |> render(:created, draft: draft)
    end
  end

  # POST /api/v1/drafts/:id/approve
  def approve(conn, %{"id" => id}) do
    draft = ContentGeneration.get_draft!(id)

    with {:ok, draft} <- ContentGeneration.mark_draft_approved(draft) do
      render(conn, :approved, draft: draft)
    end
  end

  # POST /api/v1/drafts/:id/reject
  def reject(conn, %{"id" => id, "reason" => reason}) do
    draft = ContentGeneration.get_draft!(id)

    with {:ok, draft} <- ContentGeneration.mark_draft_rejected(draft, reason) do
      render(conn, :rejected, draft: draft)
    end
  end

  # POST /api/v1/drafts/:id/score
  def score(conn, %{"id" => id, "model_name" => model_name, "score" => score_params}) do
    draft = ContentGeneration.get_draft!(id)

    attrs = %{
      draft_id: draft.id,
      model_name: model_name,
      accuracy_score: score_params["accuracy_score"],
      seo_score: score_params["seo_score"],
      eev_score: score_params["eev_score"],
      composite_score: score_params["composite_score"],
      critique: score_params["critique"]
    }

    with {:ok, score} <- ContentGeneration.create_draft_score(attrs) do
      render(conn, :scored, draft: draft, score: score)
    end
  end

  # POST /api/v1/products/:product_id/generate
  def generate(conn, %{"product_id" => product_id, "options" => options}) do
    product = Products.get_product!(product_id)

    if is_nil(product.voice_profile) do
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: "Product must have a voice_profile before generating content"})
    else
      # Enqueue content brief generation first
      Oban.insert(%Oban.Job{
        queue: :content_generation,
        worker: "ContentForge.Jobs.ContentBriefGenerator",
        args: %{"product_id" => product_id, "force_rewrite" => false},
        max_attempts: 3
      })

      # Then enqueue bulk generation (will wait for brief)
      Oban.insert(%Oban.Job{
        queue: :content_generation,
        worker: "ContentForge.Jobs.OpenClawBulkGenerator",
        args: %{"product_id" => product_id, "options" => options || %{}},
        max_attempts: 3
      })

      json(conn, %{message: "Generation job enqueued", product_id: product_id})
    end
  end

  # GET /api/v1/products/:product_id/brief
  def get_brief(conn, %{"product_id" => product_id}) do
    brief = ContentGeneration.get_latest_content_brief_for_product(product_id)

    if brief do
      versions = ContentGeneration.list_brief_versions_for_brief(brief.id)

      json(conn, %{
        id: brief.id,
        product_id: brief.product_id,
        version: brief.version,
        content: brief.content,
        model_used: brief.model_used,
        inserted_at: brief.inserted_at,
        versions: Enum.map(versions, fn v -> %{
          version: v.version,
          content: v.content,
          rewrite_reason: v.rewrite_reason,
          inserted_at: v.inserted_at
        } end)
      })
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "No content brief found for this product"})
    end
  end

  # Helper functions
  defp get_query_param(conn, key) do
    case Map.get(conn.params, key) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  defp parse_float(nil), do: nil
  defp parse_float(value) do
    case Float.parse(value) do
      {num, _} -> num
      :error -> nil
    end
  end
end