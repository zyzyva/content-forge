defmodule ContentForge.OpenClawTools.ListRecentAssets do
  @moduledoc """
  OpenClaw tool: lists a product's recent non-deleted assets so the
  agent can answer "what have I uploaded recently for Acme?".

  Reuses `ContentForge.ProductAssets.list_assets/2`, which defaults
  to excluding soft-deleted rows.

  Params:

    * `"product"` - optional, resolved via `ProductResolver`. When
      omitted on the SMS channel the sender's registered phone
      supplies the product context.
    * `"limit"` - optional integer, default 10, clamped to
      `[1, 50]`.
    * `"media_type"` - optional `"image" | "video"` filter.
    * `"tag"` - optional single tag for overlap filtering (forwarded
      to the context function's `:tag` key).

  Result: `%{product_id, product_name, count, assets: [...]}`. Each
  asset carries `id, filename, media_type, status, mime_type,
  byte_size, tags, description, uploaded_at` with `uploaded_at` as
  an ISO-8601 string.

  Errors: `:missing_product_context`, `:product_not_found`,
  `:ambiguous_product`.
  """

  alias ContentForge.OpenClawTools.ProductResolver
  alias ContentForge.ProductAssets

  @default_limit 10
  @limit_min 1
  @limit_max 50

  @spec call(map(), map()) :: {:ok, map()} | {:error, term()}
  def call(ctx, params) when is_map(params) do
    with {:ok, product} <- ProductResolver.resolve(ctx, params) do
      opts = build_opts(params)
      assets = ProductAssets.list_assets(product.id, opts)

      {:ok,
       %{
         product_id: product.id,
         product_name: product.name,
         count: length(assets),
         assets: Enum.map(assets, &serialize_asset/1)
       }}
    end
  end

  defp build_opts(params) do
    [limit: fetch_limit(params)]
    |> maybe_put(:media_type, allowed_media_type(Map.get(params, "media_type")))
    |> maybe_put(:tag, non_empty_binary(Map.get(params, "tag")))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp allowed_media_type("image"), do: "image"
  defp allowed_media_type("video"), do: "video"
  defp allowed_media_type(_), do: nil

  defp non_empty_binary(value) when is_binary(value) and value != "", do: value
  defp non_empty_binary(_), do: nil

  defp fetch_limit(params) do
    params
    |> Map.get("limit", @default_limit)
    |> clamp_limit()
  end

  defp clamp_limit(value) when is_integer(value) do
    value |> max(@limit_min) |> min(@limit_max)
  end

  defp clamp_limit(_), do: @default_limit

  defp serialize_asset(asset) do
    %{
      id: asset.id,
      filename: asset.filename,
      media_type: asset.media_type,
      status: asset.status,
      mime_type: asset.mime_type,
      byte_size: asset.byte_size,
      tags: asset.tags || [],
      description: asset.description,
      uploaded_at: iso8601(asset.uploaded_at)
    }
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
