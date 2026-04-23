defmodule ContentForge.OpenClawTools.CreateUploadLink do
  @moduledoc """
  OpenClaw tool: generates a presigned upload URL the operator
  (or any channel user) can PUT an asset to directly.

  Authorization: requires `:submitter` or higher. SMS callers are
  resolved through `ProductPhone`; CLI callers through
  `OperatorIdentity`. See
  `ContentForge.OpenClawTools.Authorization` for the full
  hierarchy.

  Params (optional when the channel can supply a product context,
  required otherwise):

    * `"product"` - product name OR product id. Both paths work;
      name is the usual agent-facing shape (`"create an upload
      link for Acme"`). Falls back to case-insensitive substring
      match so agents can pass a partial name. When omitted, the
      SMS channel resolves the product via the sender's
      registered `ProductPhone`.

  Params (optional):

    * `"filename"` - defaults to `"upload.bin"`.
    * `"content_type"` - defaults to `"application/octet-stream"`.
      Validated against
      `ContentForge.ProductAssets.AcceptedContentTypes` (the same
      allow-list the operator dashboard enforces in 13.1b); an
      unsupported type returns `:unsupported_content_type`
      without touching storage.
    * `"expires_in_seconds"` - clamped to the configurable
      ceiling at `:content_forge, :open_claw_tools,
      :max_upload_expires_seconds` (default 3600 = one hour).
      Values at or below zero fall back to the default 900. This
      prevents an agent turn from slipping a forever-link past
      the clamp.

  Returns `{:ok, %{url, storage_key, expires_at,
  expires_in_seconds, product_id, product_name}}` on success or
  `{:error, reason}` classified as:

    * `:forbidden` - caller does not have the required role on
      the resolved product.
    * `:missing_product_context` - no explicit `product` supplied
      and the channel could not derive one from the sender.
    * `:product_not_found` - no product matches the supplied
      name or id.
    * `:ambiguous_product` - multiple products match the
      supplied name.
    * `:unsupported_content_type` - requested `content_type` is
      not on the shared allow-list.
    * `{:presign_failed, reason}` - storage adapter rejected
      the presign call.
  """

  alias ContentForge.OpenClawTools.Authorization
  alias ContentForge.OpenClawTools.ProductResolver
  alias ContentForge.ProductAssets.AcceptedContentTypes

  @default_filename "upload.bin"
  @default_content_type "application/octet-stream"
  @default_expires_in_seconds 900
  @default_max_expires_in_seconds 3600

  @spec call(map(), map()) :: {:ok, map()} | {:error, term()}
  def call(ctx, params) when is_map(params) do
    with {:ok, product} <- ProductResolver.resolve(ctx, params),
         :ok <- Authorization.require(Map.put(ctx, :product, product), :submitter),
         {:ok, content_type} <- fetch_content_type(params),
         filename <- Map.get(params, "filename", @default_filename),
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

  # --- content type ---------------------------------------------------------

  defp fetch_content_type(params) do
    content_type = Map.get(params, "content_type", @default_content_type)

    cond do
      content_type == @default_content_type -> {:ok, content_type}
      AcceptedContentTypes.allowed?(content_type) -> {:ok, content_type}
      true -> {:error, :unsupported_content_type}
    end
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

  # --- expires clamp --------------------------------------------------------

  defp fetch_expires_in(params) do
    params
    |> Map.get("expires_in_seconds")
    |> clamp_expires_in()
  end

  defp clamp_expires_in(value) when is_integer(value) and value > 0 do
    min(value, max_expires_in_seconds())
  end

  defp clamp_expires_in(_), do: @default_expires_in_seconds

  defp max_expires_in_seconds do
    :content_forge
    |> Application.get_env(:open_claw_tools, [])
    |> Keyword.get(:max_upload_expires_seconds, @default_max_expires_in_seconds)
  end
end
