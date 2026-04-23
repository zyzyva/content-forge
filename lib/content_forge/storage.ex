defmodule ContentForge.Storage do
  @moduledoc """
  R2/S3 storage client for storing and retrieving snapshots, screenshots, and other assets.
  """
  require Logger

  @bucket Application.compile_env(:content_forge, :r2_bucket, "content-forge")
  @region Application.compile_env(:content_forge, :r2_region, "auto")

  def put_object(key, body, opts \\ []) when is_binary(key) and is_binary(body) do
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")

    case ExAws.S3.put_object(@bucket, key, body, [content_type: content_type] |> Enum.into(%{}))
         |> ExAws.request() do
      {:ok, _} ->
        Logger.info("Stored object to R2: #{key}")
        {:ok, "https://#{@bucket}.#{@region}.r2.cloudflarestorage.com/#{key}"}

      {:error, reason} ->
        Logger.error("Failed to store object to R2: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def get_object(key) when is_binary(key) do
    case ExAws.S3.get_object(@bucket, key) |> ExAws.request() do
      {:ok, %{body: body}} ->
        {:ok, body}

      {:error, reason} ->
        Logger.error("Failed to get object from R2: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def delete_object(key) when is_binary(key) do
    case ExAws.S3.delete_object(@bucket, key) |> ExAws.request() do
      {:ok, _} ->
        Logger.info("Deleted object from R2: #{key}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to delete object from R2: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def get_publicUrl(key) when is_binary(key) do
    "https://#{@bucket}.#{@region}.r2.cloudflarestorage.com/#{key}"
  end

  @doc """
  Generates a presigned PUT URL that a client can use to upload directly
  to R2. `expires_in` defaults to 900 seconds (15 minutes). The URL
  pins the object key and the content-type query parameter; a client
  that sent a different content type would be rejected by R2.
  """
  def presigned_put_url(key, content_type, opts \\ [])
      when is_binary(key) and is_binary(content_type) do
    expires_in = Keyword.get(opts, :expires_in, 900)
    config = ExAws.Config.new(:s3)

    ExAws.S3.presigned_url(config, :put, @bucket, key,
      expires_in: expires_in,
      query_params: [{"Content-Type", content_type}]
    )
  end
end
