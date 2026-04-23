defmodule ContentForge.OpenClawTools.CreateUploadLink do
  @moduledoc """
  OpenClaw tool: generates a presigned upload URL the operator
  (or any channel user) can PUT an asset to directly.

  Params (required):

    * `"product"` - product name OR product id. Both paths work;
      name is the usual agent-facing shape (`"create an upload
      link for Acme"`). Falls back to fuzzy match on
      `String.contains?` so agents can pass a partial name.

  Params (optional):

    * `"filename"` - defaults to `"upload.bin"`.
    * `"content_type"` - defaults to `"application/octet-stream"`.
    * `"expires_in_seconds"` - defaults to 900 (15 minutes).

  Returns `{:ok, %{url, storage_key, expires_at,
  expires_in_seconds, product_id, product_name}}` on success or
  `{:error, reason}` classified as:

    * `:product_not_found` - no product matches the supplied
      name or id
    * `:ambiguous_product` - multiple products match the
      supplied name
    * `{:presign_failed, reason}` - storage adapter rejected
      the presign call
  """

  alias ContentForge.Products
  alias ContentForge.Products.Product

  @default_filename "upload.bin"
  @default_content_type "application/octet-stream"
  @default_expires_in_seconds 900

  @spec call(map(), map()) :: {:ok, map()} | {:error, term()}
  def call(_ctx, params) when is_map(params) do
    with {:ok, product} <- resolve_product(Map.get(params, "product")),
         filename <- Map.get(params, "filename", @default_filename),
         content_type <- Map.get(params, "content_type", @default_content_type),
         expires_in <- fetch_expires_in(params),
         storage_key <- build_storage_key(product.id, filename),
         {:ok, url} <- presign_put(storage_key, content_type, expires_in) do
      expires_at = DateTime.add(DateTime.utc_now(), expires_in, :second)

      {:ok,
       %{
         url: url,
         storage_key: storage_key,
         expires_at: DateTime.to_iso8601(expires_at),
         expires_in_seconds: expires_in,
         product_id: product.id,
         product_name: product.name
       }}
    end
  end

  # --- product resolution ---------------------------------------------------

  defp resolve_product(nil), do: {:error, :product_not_found}
  defp resolve_product(""), do: {:error, :product_not_found}

  defp resolve_product(id_or_name) when is_binary(id_or_name) do
    case Products.get_product(id_or_name) do
      %Product{} = product ->
        {:ok, product}

      nil ->
        resolve_by_name(id_or_name)
    end
  rescue
    Ecto.Query.CastError -> resolve_by_name(id_or_name)
  end

  defp resolve_by_name(name) do
    case fuzzy_match(name) do
      [product] -> {:ok, product}
      [] -> {:error, :product_not_found}
      [_ | _] -> {:error, :ambiguous_product}
    end
  end

  defp fuzzy_match(needle) do
    lowered = String.downcase(needle)

    Products.list_products()
    |> Enum.filter(fn %Product{name: name} ->
      String.contains?(String.downcase(name), lowered)
    end)
  end

  # --- presign --------------------------------------------------------------

  defp build_storage_key(product_id, filename) do
    uuid = Ecto.UUID.generate()
    safe = sanitize_filename(filename)
    "products/#{product_id}/assets/#{uuid}/#{safe}"
  end

  defp sanitize_filename(filename) do
    filename
    |> Path.basename()
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
  end

  defp presign_put(storage_key, content_type, expires_in) do
    case storage_impl().presigned_put_url(storage_key, content_type, expires_in: expires_in) do
      {:ok, url} -> {:ok, url}
      {:error, reason} -> {:error, {:presign_failed, reason}}
    end
  end

  defp storage_impl do
    Application.get_env(:content_forge, :asset_storage_impl, ContentForge.Storage)
  end

  defp fetch_expires_in(params) do
    case Map.get(params, "expires_in_seconds") do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_expires_in_seconds
    end
  end
end
