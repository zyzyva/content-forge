defmodule ContentForge.ProductAssets do
  @moduledoc """
  Context for product-level assets (images and short videos uploaded for
  use in generation and publishing).

  This module owns persistence and queries for `ProductAsset` rows. No
  upload, storage, or processing logic lives here - those come in the
  following slices (presigned uploads in 13.1b, LiveView in 13.1c,
  Media Forge dispatch in 13.1d and 13.1e).
  """

  import Ecto.Query

  alias ContentForge.ProductAssets.ProductAsset
  alias ContentForge.Repo

  @default_statuses ~w(pending processed failed)

  @doc "Creates a new product asset. Returns `{:ok, asset}` or `{:error, changeset}`."
  @spec create_asset(map()) :: {:ok, ProductAsset.t()} | {:error, Ecto.Changeset.t()}
  def create_asset(attrs) when is_map(attrs) do
    %ProductAsset{}
    |> ProductAsset.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Fetches an asset by id, raises `Ecto.NoResultsError` if not found."
  @spec get_asset!(Ecto.UUID.t()) :: ProductAsset.t()
  def get_asset!(id), do: Repo.get!(ProductAsset, id)

  @doc "Fetches an asset by id, returns nil if not found."
  @spec get_asset(Ecto.UUID.t()) :: ProductAsset.t() | nil
  def get_asset(id), do: Repo.get(ProductAsset, id)

  @doc "Looks up an asset by `product_id` and `storage_key`. Returns nil if none."
  @spec get_asset_by_storage_key(Ecto.UUID.t(), String.t()) :: ProductAsset.t() | nil
  def get_asset_by_storage_key(product_id, storage_key)
      when is_binary(storage_key) do
    Repo.get_by(ProductAsset, product_id: product_id, storage_key: storage_key)
  end

  @doc """
  Lists assets for a product. Options:

    * `:tag`        - filter to assets carrying this tag
    * `:media_type` - "image" or "video"
    * `:status`     - override the default "not deleted" filter. Pass
                      `"deleted"` or a list of statuses to include soft
                      deleted rows in the result.
    * `:sort_by`    - `:uploaded_at` (default) or `:inserted_at`
    * `:limit`      - cap the number of rows returned

  Soft-deleted rows are excluded by default.
  """
  @spec list_assets(Ecto.UUID.t(), keyword()) :: [ProductAsset.t()]
  def list_assets(product_id, opts \\ []) when is_list(opts) do
    ProductAsset
    |> where([a], a.product_id == ^product_id)
    |> apply_status_filter(Keyword.get(opts, :status))
    |> apply_tag_filter(Keyword.get(opts, :tag))
    |> apply_media_type_filter(Keyword.get(opts, :media_type))
    |> apply_sort(Keyword.get(opts, :sort_by, :uploaded_at))
    |> apply_limit(Keyword.get(opts, :limit))
    |> Repo.all()
  end

  @doc """
  Returns the sorted-unique list of tags currently used across the
  product's non-deleted assets. Useful for tag autocomplete.
  """
  @spec list_distinct_tags(Ecto.UUID.t()) :: [String.t()]
  def list_distinct_tags(product_id) do
    ProductAsset
    |> where([a], a.product_id == ^product_id)
    |> where([a], a.status != "deleted")
    |> select([a], fragment("unnest(?)", a.tags))
    |> distinct(true)
    |> Repo.all()
    |> Enum.sort()
  end

  @doc "Updates an asset with the given attributes via the standard changeset."
  @spec update_asset(ProductAsset.t(), map()) ::
          {:ok, ProductAsset.t()} | {:error, Ecto.Changeset.t()}
  def update_asset(%ProductAsset{} = asset, attrs) do
    asset
    |> ProductAsset.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Transitions a pending asset to `processed` and persists the
  dimensions/duration that Media Forge probed.
  """
  @spec mark_processed(ProductAsset.t(), map()) ::
          {:ok, ProductAsset.t()} | {:error, Ecto.Changeset.t()}
  def mark_processed(%ProductAsset{} = asset, attrs) when is_map(attrs) do
    asset
    |> ProductAsset.mark_processed_changeset(attrs)
    |> Repo.update()
  end

  @doc "Flips an asset to `failed` and records the given error string."
  @spec mark_failed(ProductAsset.t(), String.t()) ::
          {:ok, ProductAsset.t()} | {:error, Ecto.Changeset.t()}
  def mark_failed(%ProductAsset{} = asset, reason) when is_binary(reason) do
    asset
    |> ProductAsset.mark_failed_changeset(reason)
    |> Repo.update()
  end

  @doc "Soft-deletes an asset: sets `status = \"deleted\"` without removing the row."
  @spec soft_delete_asset(ProductAsset.t()) ::
          {:ok, ProductAsset.t()} | {:error, Ecto.Changeset.t()}
  def soft_delete_asset(%ProductAsset{} = asset) do
    asset
    |> ProductAsset.soft_delete_changeset()
    |> Repo.update()
  end

  # --- query helpers ------------------------------------------------------

  defp apply_status_filter(query, nil) do
    where(query, [a], a.status in @default_statuses)
  end

  defp apply_status_filter(query, status) when is_binary(status) do
    where(query, [a], a.status == ^status)
  end

  defp apply_status_filter(query, statuses) when is_list(statuses) do
    where(query, [a], a.status in ^statuses)
  end

  defp apply_tag_filter(query, nil), do: query

  defp apply_tag_filter(query, tag) when is_binary(tag) do
    where(query, [a], ^tag in a.tags)
  end

  defp apply_media_type_filter(query, nil), do: query

  defp apply_media_type_filter(query, media_type) when is_binary(media_type) do
    where(query, [a], a.media_type == ^media_type)
  end

  defp apply_sort(query, :uploaded_at), do: order_by(query, [a], desc: a.uploaded_at)
  defp apply_sort(query, :inserted_at), do: order_by(query, [a], desc: a.inserted_at)
  defp apply_sort(query, _), do: order_by(query, [a], desc: a.uploaded_at)

  defp apply_limit(query, nil), do: query
  defp apply_limit(query, n) when is_integer(n) and n > 0, do: limit(query, ^n)
end
