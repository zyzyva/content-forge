defmodule ContentForgeWeb.ProductAssetController do
  @moduledoc """
  Controller for the product-asset upload flow.

  Clients call `presigned_upload` to get a time-limited PUT URL that
  uploads bytes directly to R2 (bypassing Phoenix on the hot path).
  Once the PUT succeeds, the client calls `register` with the
  previously-returned storage key plus the upload's metadata; this
  creates a `ProductAsset` row in `pending` and enqueues the right
  processing job based on `media_type`.
  """
  use ContentForgeWeb, :controller

  alias ContentForge.Jobs.AssetImageProcessor
  alias ContentForge.Jobs.AssetVideoProcessor
  alias ContentForge.ProductAssets
  alias ContentForge.ProductAssets.ProductAsset
  alias ContentForge.Products

  @image_content_types ~w(image/jpeg image/png image/webp image/heic)
  @video_content_types ~w(video/mp4 video/quicktime video/x-m4v)
  @allowed_content_types @image_content_types ++ @video_content_types

  @image_byte_cap 50 * 1_024 * 1_024
  @video_byte_cap 500 * 1_024 * 1_024

  @presign_expires_seconds 900

  # --- presigned_upload ----------------------------------------------------

  def presigned_upload(conn, %{"product_id" => product_id} = params) do
    with {:ok, _product} <- fetch_product(product_id),
         {:ok, filename} <- require_param(params, "filename"),
         {:ok, content_type} <- require_param(params, "content_type"),
         {:ok, byte_size} <- require_int_param(params, "byte_size"),
         :ok <- validate_content_type(content_type),
         :ok <- validate_byte_size(content_type, byte_size),
         storage_key = build_storage_key(product_id, filename),
         {:ok, url} <- presign_put(storage_key, content_type) do
      expires_at = DateTime.add(DateTime.utc_now(), @presign_expires_seconds, :second)

      conn
      |> put_status(:ok)
      |> json(%{
        "data" => %{
          "url" => url,
          "storage_key" => storage_key,
          "expires_at" => DateTime.to_iso8601(expires_at),
          "expires_in_seconds" => @presign_expires_seconds,
          "content_type" => content_type,
          "byte_size" => byte_size
        }
      })
    end
    |> render_error_or_response(conn)
  end

  # --- register -----------------------------------------------------------

  def register(conn, %{"product_id" => product_id} = params) do
    with {:ok, _product} <- fetch_product(product_id),
         {:ok, storage_key} <- require_param(params, "storage_key"),
         {:ok, filename} <- require_param(params, "filename"),
         {:ok, content_type} <- require_param(params, "content_type"),
         {:ok, byte_size} <- require_int_param(params, "byte_size"),
         :ok <- validate_content_type(content_type),
         :ok <- validate_byte_size(content_type, byte_size),
         attrs = asset_attrs(product_id, params, storage_key, filename, content_type, byte_size),
         {:ok, asset} <- ProductAssets.create_asset(attrs) do
      enqueue_processing(asset)

      conn
      |> put_status(:created)
      |> json(%{"data" => asset_json(asset)})
    end
    |> render_error_or_response(conn)
  end

  # --- helpers: error rendering ------------------------------------------

  defp render_error_or_response(%Plug.Conn{} = conn, _prior), do: conn

  defp render_error_or_response({:error, reason}, conn),
    do: render_error(conn, reason)

  defp render_error(conn, :product_not_found),
    do: send_error(conn, 404, "product not found")

  defp render_error(conn, {:missing_param, field}),
    do: send_error(conn, 422, "missing required field: #{field}")

  defp render_error(conn, {:invalid_integer, field}),
    do: send_error(conn, 422, "field must be a positive integer: #{field}")

  defp render_error(conn, :unsupported_content_type) do
    conn
    |> put_status(415)
    |> json(%{
      "error" => "unsupported content type",
      "allowed" => @allowed_content_types
    })
  end

  defp render_error(conn, {:byte_size_exceeded, limit, got}) do
    conn
    |> put_status(413)
    |> json(%{
      "error" => "payload too large",
      "max_bytes" => limit,
      "got_bytes" => got
    })
  end

  defp render_error(conn, {:presign_failed, reason}),
    do: send_error(conn, 502, "presign failed: #{inspect(reason)}")

  defp render_error(conn, %Ecto.Changeset{} = cs) do
    conn
    |> put_status(422)
    |> json(%{"errors" => changeset_errors(cs)})
  end

  defp send_error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{"error" => message})
  end

  defp changeset_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
  end

  # --- helpers: validation ------------------------------------------------

  defp fetch_product(product_id) do
    case Products.get_product(product_id) do
      nil -> {:error, :product_not_found}
      product -> {:ok, product}
    end
  end

  defp require_param(params, field) do
    case params[field] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_param, field}}
    end
  end

  defp require_int_param(params, field) do
    case params[field] do
      n when is_integer(n) and n > 0 -> {:ok, n}
      n when is_binary(n) -> parse_int(field, n)
      _ -> {:error, {:invalid_integer, field}}
    end
  end

  defp parse_int(field, str) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, {:invalid_integer, field}}
    end
  end

  defp validate_content_type(type) when type in @allowed_content_types, do: :ok
  defp validate_content_type(_), do: {:error, :unsupported_content_type}

  defp validate_byte_size(type, size) when type in @image_content_types do
    if size <= @image_byte_cap,
      do: :ok,
      else: {:error, {:byte_size_exceeded, @image_byte_cap, size}}
  end

  defp validate_byte_size(type, size) when type in @video_content_types do
    if size <= @video_byte_cap,
      do: :ok,
      else: {:error, {:byte_size_exceeded, @video_byte_cap, size}}
  end

  defp validate_byte_size(_type, _size), do: :ok

  # --- helpers: storage key + presign ------------------------------------

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

  defp presign_put(storage_key, content_type) do
    case storage_impl().presigned_put_url(storage_key, content_type,
           expires_in: @presign_expires_seconds
         ) do
      {:ok, url} -> {:ok, url}
      {:error, reason} -> {:error, {:presign_failed, reason}}
    end
  end

  defp storage_impl do
    Application.get_env(:content_forge, :asset_storage_impl, ContentForge.Storage)
  end

  # --- helpers: register + enqueue ---------------------------------------

  defp asset_attrs(product_id, params, storage_key, filename, content_type, byte_size) do
    %{
      product_id: product_id,
      storage_key: storage_key,
      filename: filename,
      mime_type: content_type,
      media_type: media_type_for(content_type),
      byte_size: byte_size,
      uploaded_at: DateTime.utc_now(),
      uploader: params["uploader"],
      tags: params["tags"] || [],
      description: params["description"]
    }
  end

  defp media_type_for(type) when type in @image_content_types, do: "image"
  defp media_type_for(type) when type in @video_content_types, do: "video"

  defp enqueue_processing(%ProductAsset{media_type: "image", id: id}) do
    %{"asset_id" => id} |> AssetImageProcessor.new() |> Oban.insert()
  end

  defp enqueue_processing(%ProductAsset{media_type: "video", id: id}) do
    %{"asset_id" => id} |> AssetVideoProcessor.new() |> Oban.insert()
  end

  defp asset_json(%ProductAsset{} = asset) do
    %{
      "id" => asset.id,
      "product_id" => asset.product_id,
      "storage_key" => asset.storage_key,
      "filename" => asset.filename,
      "mime_type" => asset.mime_type,
      "media_type" => asset.media_type,
      "byte_size" => asset.byte_size,
      "status" => asset.status,
      "tags" => asset.tags,
      "uploaded_at" => DateTime.to_iso8601(asset.uploaded_at)
    }
  end
end
