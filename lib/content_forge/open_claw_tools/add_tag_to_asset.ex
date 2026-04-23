defmodule ContentForge.OpenClawTools.AddTagToAsset do
  @moduledoc """
  OpenClaw tool: adds a single tag to a product's asset so the
  agent can bucket uploads (by season, client, campaign, etc.)
  through conversation.

  Authorization: requires `:submitter` or higher on the resolved
  product.

  Params (required):

    * `"asset_id"` - exact UUID of a `ProductAsset` owned by the
      resolved product. A cross-product id collapses to
      `:not_found` without leaking the asset's existence.
    * `"tag"` - 1..40 chars after trimming; the tool lowercases
      the tag before persisting so `"Spring"` and `"spring"` do
      not split into two buckets.

  Params (optional):

    * `"product"` - resolved via `ProductResolver`; SMS callers
      can omit this once a phone is registered.

  Returns `{:ok, %{asset_id, tags}}` where `tags` is the merged,
  deduplicated set persisted to the asset.

  Errors: `:missing_product_context`, `:product_not_found`,
  `:ambiguous_product`, `:forbidden`, `:not_found`,
  `:invalid_tag`, `{:invalid_params, errors}` (for changeset
  errors from the underlying `ProductAssets.add_tag/2`).
  """

  alias ContentForge.OpenClawTools.Authorization
  alias ContentForge.OpenClawTools.ProductResolver
  alias ContentForge.ProductAssets
  alias ContentForge.ProductAssets.ProductAsset

  @tag_min 1
  @tag_max 40

  @spec call(map(), map()) :: {:ok, map()} | {:error, term()}
  def call(ctx, params) when is_map(params) do
    with {:ok, product} <- ProductResolver.resolve(ctx, params),
         :ok <- Authorization.require(Map.put(ctx, :product, product), :submitter),
         {:ok, tag} <- fetch_tag(params),
         {:ok, asset} <- scoped_asset(product, params),
         {:ok, updated} <- persist_tag(asset, tag) do
      {:ok, %{asset_id: updated.id, tags: updated.tags}}
    end
  end

  # --- tag validation -------------------------------------------------------

  defp fetch_tag(params) do
    raw = Map.get(params, "tag", "")

    case raw |> to_trimmed_string() |> String.downcase() do
      "" -> {:error, :invalid_tag}
      tag when byte_size(tag) > @tag_max -> {:error, :invalid_tag}
      tag when byte_size(tag) < @tag_min -> {:error, :invalid_tag}
      tag -> {:ok, tag}
    end
  end

  defp to_trimmed_string(value) when is_binary(value), do: String.trim(value)
  defp to_trimmed_string(_), do: ""

  # --- scoped asset lookup --------------------------------------------------

  defp scoped_asset(product, params) do
    with asset_id when is_binary(asset_id) and asset_id != "" <- Map.get(params, "asset_id"),
         %ProductAsset{product_id: pid} = asset <- safe_get_asset(asset_id),
         true <- pid == product.id do
      {:ok, asset}
    else
      _ -> {:error, :not_found}
    end
  end

  defp safe_get_asset(id) do
    ProductAssets.get_asset(id)
  rescue
    Ecto.Query.CastError -> nil
  end

  # --- persistence ----------------------------------------------------------

  defp persist_tag(%ProductAsset{} = asset, tag) do
    case ProductAssets.add_tag(asset, tag) do
      {:ok, updated} -> {:ok, updated}
      {:error, %Ecto.Changeset{} = cs} -> {:error, {:invalid_params, changeset_errors(cs)}}
    end
  end

  defp changeset_errors(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
  end
end
