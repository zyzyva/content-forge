defmodule ContentForge.Products do
  @moduledoc """
  The Products context handles CRUD operations for products, blog webhooks,
  snapshots, competitor accounts, and competitor intel.
  """
  import Ecto.Query
  alias ContentForge.Repo
  alias ContentForge.Products.Product
  alias ContentForge.Products.BlogWebhook
  alias ContentForge.Products.ProductSnapshot
  alias ContentForge.Products.CompetitorAccount
  alias ContentForge.Products.CompetitorPost
  alias ContentForge.Products.CompetitorPostComment
  alias ContentForge.Products.CompetitorIntel
  alias ContentForge.Products.PendingIntelSynthesis
  alias ContentForge.Products.ProductMemory

  # Product CRUD

  def list_products do
    Repo.all(Product)
  end

  def get_product!(id), do: Repo.get!(Product, id)

  def get_product(id), do: Repo.get(Product, id)

  def get_product_by_name(name), do: Repo.get_by(Product, name: name)

  def create_product(attrs \\ %{}) do
    %Product{}
    |> Product.changeset(attrs)
    |> Repo.insert()
  end

  def update_product(%Product{} = product, attrs) do
    product
    |> Product.changeset(attrs)
    |> Repo.update()
  end

  def delete_product(%Product{} = product) do
    Repo.delete(product)
  end

  # BlogWebhook CRUD

  def list_blog_webhooks do
    Repo.all(BlogWebhook)
  end

  def list_blog_webhooks_for_product(product_id) do
    BlogWebhook
    |> where(product_id: ^product_id)
    |> Repo.all()
  end

  def get_blog_webhook!(id), do: Repo.get!(BlogWebhook, id)

  def get_blog_webhook(id), do: Repo.get(BlogWebhook, id)

  def create_blog_webhook(attrs \\ %{}) do
    %BlogWebhook{}
    |> BlogWebhook.changeset(attrs)
    |> Repo.insert()
  end

  def update_blog_webhook(%BlogWebhook{} = webhook, attrs) do
    webhook
    |> BlogWebhook.changeset(attrs)
    |> Repo.update()
  end

  def delete_blog_webhook(%BlogWebhook{} = webhook) do
    Repo.delete(webhook)
  end

  def list_active_blog_webhooks_for_product(product_id) do
    BlogWebhook
    |> where(product_id: ^product_id, active: true)
    |> Repo.all()
  end

  # ProductSnapshot CRUD

  def list_product_snapshots do
    Repo.all(ProductSnapshot)
  end

  def list_product_snapshots_for_product(product_id) do
    ProductSnapshot
    |> where(product_id: ^product_id)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def get_product_snapshot!(id), do: Repo.get!(ProductSnapshot, id)

  def get_product_snapshot(id), do: Repo.get(ProductSnapshot, id)

  def get_latest_snapshot_for_product(product_id, type) do
    ProductSnapshot
    |> where(product_id: ^product_id, snapshot_type: ^type)
    |> order_by(desc: :inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  def create_product_snapshot(attrs \\ %{}) do
    %ProductSnapshot{}
    |> ProductSnapshot.changeset(attrs)
    |> Repo.insert()
  end

  def delete_product_snapshot(%ProductSnapshot{} = snapshot) do
    Repo.delete(snapshot)
  end

  # CompetitorAccount CRUD

  def list_competitor_accounts do
    Repo.all(CompetitorAccount)
  end

  def list_competitor_accounts_for_product(product_id) do
    CompetitorAccount
    |> where(product_id: ^product_id)
    |> Repo.all()
  end

  def list_active_competitor_accounts_for_product(product_id) do
    CompetitorAccount
    |> where(product_id: ^product_id, active: true)
    |> Repo.all()
  end

  def get_competitor_account!(id), do: Repo.get!(CompetitorAccount, id)

  def get_competitor_account(id), do: Repo.get(CompetitorAccount, id)

  def create_competitor_account(attrs \\ %{}) do
    %CompetitorAccount{}
    |> CompetitorAccount.changeset(attrs)
    |> Repo.insert()
  end

  def update_competitor_account(%CompetitorAccount{} = account, attrs) do
    account
    |> CompetitorAccount.changeset(attrs)
    |> Repo.update()
  end

  def delete_competitor_account(%CompetitorAccount{} = account) do
    Repo.delete(account)
  end

  # CompetitorPost CRUD

  def list_competitor_posts_for_account(account_id) do
    CompetitorPost
    |> where(competitor_account_id: ^account_id)
    |> order_by(desc: :posted_at)
    |> Repo.all()
  end

  def list_top_competitor_posts_for_product(product_id, max \\ 10) do
    account_ids =
      product_id
      |> list_active_competitor_accounts_for_product()
      |> Enum.map(& &1.id)

    CompetitorPost
    |> where([c], c.competitor_account_id in ^account_ids)
    |> order_by(desc: :engagement_score)
    |> limit(^max)
    |> Repo.all()
  end

  def create_competitor_post(attrs \\ %{}) do
    %CompetitorPost{}
    |> CompetitorPost.changeset(attrs)
    |> Repo.insert()
  end

  def delete_competitor_posts_for_account(account_id) do
    CompetitorPost
    |> where(competitor_account_id: ^account_id)
    |> Repo.delete_all()
  end

  @doc """
  Inserts a competitor post when no row exists for the
  `(competitor_account_id, post_id)` pair; returns the existing
  row untouched on conflict. Used by the Phase 17.5 sqlite
  importer to keep re-runs idempotent without overwriting
  metrics that may have been refined by the live scraper since
  the original import.

  Returns `{:ok, %{row: post, status: :inserted | :skipped}}` so
  callers can count fresh imports vs already-known rows.
  """
  @spec upsert_competitor_post(map()) ::
          {:ok, %{row: CompetitorPost.t(), status: :inserted | :skipped}}
          | {:error, Ecto.Changeset.t()}
  def upsert_competitor_post(attrs) when is_map(attrs) do
    account_id = attrs[:competitor_account_id] || attrs["competitor_account_id"]
    post_id = attrs[:post_id] || attrs["post_id"]

    case existing_post(account_id, post_id) do
      %CompetitorPost{} = existing ->
        {:ok, %{row: existing, status: :skipped}}

      nil ->
        with {:ok, row} <-
               %CompetitorPost{}
               |> CompetitorPost.changeset(attrs)
               |> Repo.insert() do
          {:ok, %{row: row, status: :inserted}}
        end
    end
  end

  defp existing_post(nil, _), do: nil
  defp existing_post(_, nil), do: nil

  defp existing_post(account_id, post_id) do
    Repo.one(
      from(p in CompetitorPost,
        where: p.competitor_account_id == ^account_id and p.post_id == ^post_id,
        limit: 1
      )
    )
  end

  @doc """
  Recomputes `engagement_score` for every post belonging to the
  given competitor account against the post-corpus rolling
  average (likes + comments * 2 + shares * 3). Called by the
  17.5 importer after a backfill so per-post scores reflect the
  broader corpus rather than the slice originally scraped.

  Returns `{updated_count, average_engagement}`.
  """
  @spec recompute_engagement_scores_for_account(Ecto.UUID.t()) ::
          {non_neg_integer(), float()}
  def recompute_engagement_scores_for_account(account_id) when is_binary(account_id) do
    posts = list_competitor_posts_for_account(account_id)
    average = average_engagement(posts)

    updated =
      Enum.reduce(posts, 0, fn post, acc ->
        score = relative_score(post, average)

        case post |> CompetitorPost.changeset(%{engagement_score: score}) |> Repo.update() do
          {:ok, _} -> acc + 1
          {:error, _} -> acc
        end
      end)

    {updated, average}
  end

  defp average_engagement([]), do: 0.0

  defp average_engagement(posts) do
    total =
      Enum.reduce(posts, 0, fn post, acc ->
        acc + post_engagement(post)
      end)

    total / length(posts)
  end

  defp post_engagement(%CompetitorPost{} = post) do
    (post.likes_count || 0) + (post.comments_count || 0) * 2 + (post.shares_count || 0) * 3
  end

  defp relative_score(_post, average) when average <= 0, do: 1.0

  defp relative_score(post, average), do: post_engagement(post) / average

  # CompetitorPostComment CRUD (17.1)

  @doc """
  Upserts a comment for a competitor post by `(competitor_post_id,
  platform_comment_id)`. Existing rows refresh their counts +
  text + raw_payload; the harvester is idempotent because of this.
  """
  @spec upsert_competitor_post_comment(map()) ::
          {:ok, CompetitorPostComment.t()} | {:error, Ecto.Changeset.t()}
  def upsert_competitor_post_comment(attrs) when is_map(attrs) do
    update_keys =
      ~w(author_handle text posted_at likes_count replies_count retweets_count views_count in_reply_to_id conversation_id raw_payload)a

    %CompetitorPostComment{}
    |> CompetitorPostComment.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, update_keys},
      conflict_target: [:competitor_post_id, :platform_comment_id],
      returning: true
    )
  end

  @doc "Returns every captured comment for a competitor post, newest-likes-first."
  @spec list_comments_for_post(Ecto.UUID.t()) :: [CompetitorPostComment.t()]
  def list_comments_for_post(competitor_post_id) when is_binary(competitor_post_id) do
    Repo.all(
      from(c in CompetitorPostComment,
        where: c.competitor_post_id == ^competitor_post_id,
        order_by: [desc: c.likes_count, asc: c.posted_at]
      )
    )
  end

  # CompetitorIntel CRUD

  def list_competitor_intel_for_product(product_id) do
    CompetitorIntel
    |> where(product_id: ^product_id)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def get_latest_competitor_intel_for_product(product_id) do
    CompetitorIntel
    |> where(product_id: ^product_id)
    |> order_by(desc: :inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  def create_competitor_intel(attrs \\ %{}) do
    %CompetitorIntel{}
    |> CompetitorIntel.changeset(attrs)
    |> Repo.insert()
  end

  # PendingIntelSynthesis CRUD (17.4)

  @doc """
  Creates a pending-synthesis row marking a without-key
  attempt that a Claude Code session must finish by hand.
  Returns `{:ok, row}` or `{:error, changeset}`.
  """
  @spec create_pending_intel_synthesis(map()) ::
          {:ok, PendingIntelSynthesis.t()} | {:error, Ecto.Changeset.t()}
  def create_pending_intel_synthesis(attrs) when is_map(attrs) do
    %PendingIntelSynthesis{}
    |> PendingIntelSynthesis.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Lists pending syntheses for a product, oldest-first so the queue drains FIFO."
  @spec list_pending_intel_syntheses_for_product(Ecto.UUID.t()) :: [PendingIntelSynthesis.t()]
  def list_pending_intel_syntheses_for_product(product_id) when is_binary(product_id) do
    Repo.all(
      from(p in PendingIntelSynthesis,
        where: p.product_id == ^product_id,
        order_by: [asc: p.inserted_at]
      )
    )
  end

  @doc """
  Deletes pending rows that match a freshly-stored intel
  (same `product_id` + same `window` value, including nil).
  Returns the count deleted. Used by `cf_store_intel` to
  resolve the queue when a manual synthesis lands.
  """
  @spec resolve_pending_intel_syntheses(Ecto.UUID.t(), String.t() | nil) :: non_neg_integer()
  def resolve_pending_intel_syntheses(product_id, window) when is_binary(product_id) do
    {count, _} =
      from(p in PendingIntelSynthesis, where: p.product_id == ^product_id)
      |> filter_pending_window(window)
      |> Repo.delete_all()

    count
  end

  defp filter_pending_window(query, nil), do: where(query, [p], is_nil(p.window))
  defp filter_pending_window(query, window), do: where(query, [p], p.window == ^window)

  # ProductMemory CRUD (16.3d)

  @doc """
  Inserts a `%ProductMemory{}` row. Returns `{:ok, memory}` or
  `{:error, changeset}`. The schema enforces `content` length
  (1..2000) and per-tag length (1..40); the caller normalizes
  the tags (trim + lowercase) before handing them in.
  """
  @spec create_memory(map()) :: {:ok, ProductMemory.t()} | {:error, Ecto.Changeset.t()}
  def create_memory(attrs) when is_map(attrs) do
    %ProductMemory{}
    |> ProductMemory.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists the most recent `%ProductMemory{}` rows for a product,
  newest first. `limit` defaults to 10 and is clamped at the
  caller; no upper bound is enforced here so admin tools can
  paginate through older memories if needed.
  """
  @spec list_recent_memories(Ecto.UUID.t(), pos_integer()) :: [ProductMemory.t()]
  def list_recent_memories(product_id, limit \\ 10)
      when is_binary(product_id) and is_integer(limit) and limit > 0 do
    Repo.all(
      from(m in ProductMemory,
        where: m.product_id == ^product_id,
        order_by: [desc: m.inserted_at, desc: m.id],
        limit: ^limit
      )
    )
  end
end
