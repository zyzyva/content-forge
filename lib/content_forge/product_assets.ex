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

  alias ContentForge.ProductAssets.AssetBundle
  alias ContentForge.ProductAssets.BundleAsset
  alias ContentForge.ProductAssets.ProductAsset
  alias ContentForge.Repo

  @default_statuses ~w(pending processed failed)
  @active_bundle_statuses ~w(active)
  @pubsub ContentForge.PubSub

  @doc """
  Subscribes the calling process to asset-update notifications for a
  product. Intended for use from `ContentForgeWeb` LiveViews.
  """
  @spec subscribe(Ecto.UUID.t()) :: :ok | {:error, term()}
  def subscribe(product_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(product_id))

  @doc """
  Subscribes the calling process to bundle-update notifications for a
  product. Kept on a separate topic from `subscribe/1` so a LiveView
  that only cares about asset state does not receive bundle events and
  vice versa.
  """
  @spec subscribe_bundles(Ecto.UUID.t()) :: :ok | {:error, term()}
  def subscribe_bundles(product_id),
    do: Phoenix.PubSub.subscribe(@pubsub, bundle_topic(product_id))

  defp topic(product_id), do: "product_assets:#{product_id}"
  defp bundle_topic(product_id), do: "asset_bundles:#{product_id}"

  defp broadcast_change(%ProductAsset{product_id: product_id} = asset, event) do
    Phoenix.PubSub.broadcast(@pubsub, topic(product_id), {event, asset})
    asset
  end

  defp broadcast_bundle_change(%AssetBundle{product_id: product_id} = bundle, event) do
    Phoenix.PubSub.broadcast(@pubsub, bundle_topic(product_id), {event, bundle})
    bundle
  end

  @doc "Creates a new product asset. Returns `{:ok, asset}` or `{:error, changeset}`."
  @spec create_asset(map()) :: {:ok, ProductAsset.t()} | {:error, Ecto.Changeset.t()}
  def create_asset(attrs) when is_map(attrs) do
    %ProductAsset{}
    |> ProductAsset.changeset(attrs)
    |> Repo.insert()
    |> maybe_broadcast(:asset_created)
  end

  defp maybe_broadcast({:ok, asset}, event), do: {:ok, broadcast_change(asset, event)}
  defp maybe_broadcast(other, _event), do: other

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
    |> apply_search_filter(Keyword.get(opts, :search))
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
    |> maybe_broadcast(:asset_updated)
  end

  @doc "Flips an asset to `failed` and records the given error string."
  @spec mark_failed(ProductAsset.t(), String.t()) ::
          {:ok, ProductAsset.t()} | {:error, Ecto.Changeset.t()}
  def mark_failed(%ProductAsset{} = asset, reason) when is_binary(reason) do
    asset
    |> ProductAsset.mark_failed_changeset(reason)
    |> Repo.update()
    |> maybe_broadcast(:asset_updated)
  end

  @doc """
  Adds `tag` to an asset's `tags` array if it is not already present.
  Returns the updated asset (via `maybe_broadcast/2`) or a changeset
  error. Broadcasts `:asset_updated` on success so subscribers refresh.
  """
  @spec add_tag(ProductAsset.t(), String.t()) ::
          {:ok, ProductAsset.t()} | {:error, Ecto.Changeset.t()}
  def add_tag(%ProductAsset{} = asset, tag) when is_binary(tag) do
    clean = String.trim(tag)

    if clean == "" do
      {:ok, asset}
    else
      new_tags = asset.tags |> Kernel.++([clean]) |> Enum.uniq()

      asset
      |> ProductAsset.changeset(%{tags: new_tags})
      |> Repo.update()
      |> maybe_broadcast(:asset_updated)
    end
  end

  @doc """
  Removes `tag` from an asset's `tags` array. No-op if the tag is not
  present; still broadcasts so the UI can re-render consistently.
  """
  @spec remove_tag(ProductAsset.t(), String.t()) ::
          {:ok, ProductAsset.t()} | {:error, Ecto.Changeset.t()}
  def remove_tag(%ProductAsset{} = asset, tag) when is_binary(tag) do
    new_tags = Enum.reject(asset.tags, &(&1 == tag))

    asset
    |> ProductAsset.changeset(%{tags: new_tags})
    |> Repo.update()
    |> maybe_broadcast(:asset_updated)
  end

  @doc """
  Returns the top `limit` (default 8) tags by frequency across the
  product's non-deleted assets, as `[{tag, count}]` sorted by count
  descending then alphabetically. Drives the Assets tab's tag-facet row.
  """
  @spec top_tags(Ecto.UUID.t(), pos_integer()) :: [{String.t(), non_neg_integer()}]
  def top_tags(product_id, limit \\ 8) do
    ProductAsset
    |> where([a], a.product_id == ^product_id)
    |> where([a], a.status != "deleted")
    |> select([a], fragment("unnest(?)", a.tags))
    |> Repo.all()
    |> Enum.frequencies()
    |> Enum.sort_by(fn {tag, count} -> {-count, tag} end)
    |> Enum.take(limit)
  end

  @doc "Soft-deletes an asset: sets `status = \"deleted\"` without removing the row."
  @spec soft_delete_asset(ProductAsset.t()) ::
          {:ok, ProductAsset.t()} | {:error, Ecto.Changeset.t()}
  def soft_delete_asset(%ProductAsset{} = asset) do
    asset
    |> ProductAsset.soft_delete_changeset()
    |> Repo.update()
    |> maybe_broadcast(:asset_deleted)
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

  defp apply_search_filter(query, nil), do: query
  defp apply_search_filter(query, ""), do: query

  defp apply_search_filter(query, search) when is_binary(search) do
    pattern = "%" <> search <> "%"

    where(
      query,
      [a],
      ilike(a.description, ^pattern) or
        ilike(fragment("array_to_string(?, ' ')", a.tags), ^pattern)
    )
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

  # =========================================================================
  # Asset bundles
  # =========================================================================

  @doc "Creates a new asset bundle."
  @spec create_bundle(map()) :: {:ok, AssetBundle.t()} | {:error, Ecto.Changeset.t()}
  def create_bundle(attrs) when is_map(attrs) do
    %AssetBundle{}
    |> AssetBundle.changeset(attrs)
    |> Repo.insert()
    |> maybe_broadcast_bundle(:bundle_created)
  end

  defp maybe_broadcast_bundle({:ok, bundle}, event),
    do: {:ok, broadcast_bundle_change(bundle, event)}

  defp maybe_broadcast_bundle(other, _event), do: other

  @doc """
  Fetches a bundle by id and preloads its assets in position order.
  Raises `Ecto.NoResultsError` if not found.
  """
  @spec get_bundle!(Ecto.UUID.t()) :: AssetBundle.t()
  def get_bundle!(id) do
    AssetBundle
    |> Repo.get!(id)
    |> Repo.preload(bundle_assets: [:asset])
  end

  @doc "Fetches a bundle by id, returning nil if not found."
  @spec get_bundle(Ecto.UUID.t()) :: AssetBundle.t() | nil
  def get_bundle(id) do
    case Repo.get(AssetBundle, id) do
      nil -> nil
      bundle -> Repo.preload(bundle, bundle_assets: [:asset])
    end
  end

  @doc """
  Lists bundles for a product. Options:

    * `:status` - override the default filter (which shows only
      `"active"` bundles). Pass a string or a list of strings.

  Bundles are returned newest-inserted-first.
  """
  @spec list_bundles(Ecto.UUID.t(), keyword()) :: [AssetBundle.t()]
  def list_bundles(product_id, opts \\ []) when is_list(opts) do
    AssetBundle
    |> where([b], b.product_id == ^product_id)
    |> apply_bundle_status(Keyword.get(opts, :status))
    |> order_by([b], desc: b.inserted_at)
    |> Repo.all()
  end

  defp apply_bundle_status(query, nil),
    do: where(query, [b], b.status in ^@active_bundle_statuses)

  defp apply_bundle_status(query, status) when is_binary(status),
    do: where(query, [b], b.status == ^status)

  defp apply_bundle_status(query, statuses) when is_list(statuses),
    do: where(query, [b], b.status in ^statuses)

  @doc "Updates a bundle's fields."
  @spec update_bundle(AssetBundle.t(), map()) ::
          {:ok, AssetBundle.t()} | {:error, Ecto.Changeset.t()}
  def update_bundle(%AssetBundle{} = bundle, attrs) do
    bundle
    |> AssetBundle.changeset(attrs)
    |> Repo.update()
    |> maybe_broadcast_bundle(:bundle_updated)
  end

  @doc "Archives a bundle (status -> \"archived\"); hides from the default list."
  @spec archive_bundle(AssetBundle.t()) ::
          {:ok, AssetBundle.t()} | {:error, Ecto.Changeset.t()}
  def archive_bundle(%AssetBundle{} = bundle) do
    bundle
    |> AssetBundle.archive_changeset()
    |> Repo.update()
    |> maybe_broadcast_bundle(:bundle_archived)
  end

  @doc "Soft-deletes a bundle (status -> \"deleted\") without removing the row."
  @spec soft_delete_bundle(AssetBundle.t()) ::
          {:ok, AssetBundle.t()} | {:error, Ecto.Changeset.t()}
  def soft_delete_bundle(%AssetBundle{} = bundle) do
    bundle
    |> AssetBundle.soft_delete_changeset()
    |> Repo.update()
    |> maybe_broadcast_bundle(:bundle_deleted)
  end

  # --- membership helpers --------------------------------------------------

  @doc """
  Adds an asset to a bundle. `position` defaults to the next-in-sequence
  based on the existing max position. If the asset is already a member
  this returns `{:ok, existing_join}` as a no-op rather than surfacing
  the unique-constraint error.
  """
  @spec add_asset_to_bundle(
          AssetBundle.t() | Ecto.UUID.t(),
          ProductAsset.t() | Ecto.UUID.t(),
          keyword()
        ) ::
          {:ok, BundleAsset.t()} | {:error, Ecto.Changeset.t()}
  def add_asset_to_bundle(bundle, asset, opts \\ [])

  def add_asset_to_bundle(%AssetBundle{id: bundle_id} = bundle, %ProductAsset{id: asset_id}, opts) do
    case Repo.get_by(BundleAsset, bundle_id: bundle_id, asset_id: asset_id) do
      %BundleAsset{} = existing ->
        {:ok, existing}

      nil ->
        position = Keyword.get_lazy(opts, :position, fn -> next_bundle_position(bundle_id) end)

        attrs = %{bundle_id: bundle_id, asset_id: asset_id, position: position}

        result =
          %BundleAsset{}
          |> BundleAsset.changeset(attrs)
          |> Repo.insert()

        case result do
          {:ok, row} ->
            broadcast_membership_change(bundle)
            {:ok, row}

          err ->
            err
        end
    end
  end

  def add_asset_to_bundle(bundle_id, asset_id, opts)
      when is_binary(bundle_id) and is_binary(asset_id) do
    add_asset_to_bundle(get_bundle!(bundle_id), get_asset!(asset_id), opts)
  end

  defp next_bundle_position(bundle_id) do
    BundleAsset
    |> where(bundle_id: ^bundle_id)
    |> select([b], coalesce(max(b.position), -1))
    |> Repo.one()
    |> Kernel.+(1)
  end

  defp broadcast_membership_change(%AssetBundle{} = bundle) do
    reloaded = get_bundle!(bundle.id)
    broadcast_bundle_change(reloaded, :bundle_membership_changed)
    reloaded
  end

  @doc "Removes an asset from a bundle. No-op if the asset is not a member."
  @spec remove_asset_from_bundle(AssetBundle.t(), ProductAsset.t() | Ecto.UUID.t()) ::
          :ok | {:error, term()}
  def remove_asset_from_bundle(%AssetBundle{id: bundle_id} = bundle, %ProductAsset{id: asset_id}) do
    case Repo.get_by(BundleAsset, bundle_id: bundle_id, asset_id: asset_id) do
      nil ->
        :ok

      row ->
        {:ok, _} = Repo.delete(row)
        broadcast_membership_change(bundle)
        :ok
    end
  end

  def remove_asset_from_bundle(%AssetBundle{} = bundle, asset_id) when is_binary(asset_id) do
    remove_asset_from_bundle(bundle, get_asset!(asset_id))
  end

  @doc """
  Reorders a bundle's assets. `ordered_asset_ids` is a list of asset ids
  in the desired order. Assets in the list that are not members of the
  bundle are ignored; members not in the list keep their current
  position. Runs in a transaction so partial reorders don't leak.
  """
  @spec reorder_bundle_assets(AssetBundle.t(), [Ecto.UUID.t()]) ::
          {:ok, AssetBundle.t()} | {:error, term()}
  def reorder_bundle_assets(%AssetBundle{id: bundle_id} = bundle, ordered_asset_ids)
      when is_list(ordered_asset_ids) do
    Repo.transaction(fn ->
      ordered_asset_ids
      |> Enum.with_index()
      |> Enum.each(fn {asset_id, index} ->
        BundleAsset
        |> where(bundle_id: ^bundle_id)
        |> where(asset_id: ^asset_id)
        |> Repo.update_all(set: [position: index])
      end)
    end)

    {:ok, broadcast_membership_change(bundle)}
  end
end
