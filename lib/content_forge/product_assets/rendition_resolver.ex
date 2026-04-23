defmodule ContentForge.ProductAssets.RenditionResolver do
  @moduledoc """
  Resolves the public URL that should be used when posting a given
  `%ProductAsset{}` to a given platform.

  Resolution order (mirrors the BUILDPLAN 13.5 spec):

    1. Unknown platform -fall back to the asset's primary public URL
       with no rendition call.
    2. Cached rendition row with `status: "ready"` on the
       `asset_renditions` table -return its URL without contacting
       Media Forge.
    3. Cache miss (or a previous failed attempt) -ask Media Forge to
       render. For images, `MediaForge.enqueue_image_render/1` with the
       source `storage_key`, the target spec, and the platform name.
       For videos, `MediaForge.enqueue_video_batch/1` is wired but not
       yet exercised by the publisher; this slice returns
       `{:ok, {:async, job_id}}` when Media Forge responds with a job
       id so a future slice can poll to completion.

  The full Media Forge error taxonomy passes through unchanged:
  `{:error, :not_configured}`, `{:error, {:transient, _, _}}`,
  `{:error, {:http_error, _, _}}`, `{:error, {:unexpected_status, _, _}}`,
  `{:error, {:unexpected_body, _}}`, or `{:error, _}`.

  ## Configuration

      config :content_forge, :renditions, %{
        "twitter" => %{aspect: "16:9", width: 1200, format: "jpg"},
        "instagram" => %{aspect: "1:1", width: 1080, format: "jpg"}
      }

  Platforms not present in this map are treated as "no rendition".
  """

  require Logger
  import Ecto.Query, only: [from: 2]

  alias ContentForge.MediaForge
  alias ContentForge.ProductAssets.AssetRendition
  alias ContentForge.ProductAssets.ProductAsset
  alias ContentForge.Repo
  alias ContentForge.Storage

  @type resolve_ok :: {:ok, String.t()} | {:ok, {:async, String.t()}}
  @type resolve_err :: {:error, term()}

  @doc """
  Resolves the URL for `asset` on `platform`.
  """
  @spec resolve(ProductAsset.t(), String.t()) :: resolve_ok() | resolve_err()
  def resolve(%ProductAsset{} = asset, platform) when is_binary(platform) do
    platform
    |> lookup_spec()
    |> apply_spec(asset, platform)
  end

  # --- spec lookup ---------------------------------------------------------

  defp lookup_spec(platform) do
    Application.get_env(:content_forge, :renditions, %{})
    |> Map.get(platform)
  end

  defp apply_spec(nil, asset, _platform), do: {:ok, primary_url(asset)}

  defp apply_spec(spec, asset, platform) do
    case cached_rendition(asset.id, platform) do
      %AssetRendition{status: "ready"} = rendition ->
        {:ok, Storage.get_publicUrl(rendition.storage_key)}

      existing ->
        render(asset, platform, spec, existing)
    end
  end

  defp cached_rendition(asset_id, platform) do
    from(r in AssetRendition,
      where: r.asset_id == ^asset_id and r.platform == ^platform,
      limit: 1
    )
    |> Repo.one()
  end

  # --- render dispatch -----------------------------------------------------

  defp render(%ProductAsset{media_type: "image"} = asset, platform, spec, existing) do
    %{
      "storage_key" => asset.storage_key,
      "platform" => platform,
      "spec" => spec
    }
    |> MediaForge.enqueue_image_render()
    |> handle_image_response(asset, platform, spec, existing)
  end

  defp render(%ProductAsset{media_type: "video"} = asset, platform, spec, _existing) do
    %{
      "storage_key" => asset.storage_key,
      "platform" => platform,
      "spec" => spec
    }
    |> MediaForge.enqueue_video_batch()
    |> handle_video_response(asset, platform)
  end

  defp render(%ProductAsset{} = asset, _platform, _spec, _existing),
    do: {:ok, primary_url(asset)}

  # --- image response handling --------------------------------------------

  defp handle_image_response({:ok, body}, asset, platform, spec, existing) do
    case extract_image_output(body) do
      {:ok, out} -> persist_rendition(asset, platform, spec, out, existing)
      :error -> {:error, {:unexpected_body, body}}
    end
  end

  defp handle_image_response({:error, _} = err, _asset, _platform, _spec, _existing), do: err

  # Shape-tolerant extractor for Media Forge image/render responses.
  # Accepts either a flat `storage_key` (with optional dimensions) or
  # `result: %{storage_key: _, width: _, height: _}`. Anything else is
  # :error so the caller surfaces `{:unexpected_body, body}`.
  defp extract_image_output(%{"result" => %{} = result}) do
    extract_image_output(result)
  end

  defp extract_image_output(%{"storage_key" => key} = body) when is_binary(key) do
    {:ok,
     %{
       storage_key: key,
       width: body["width"],
       height: body["height"],
       format: body["format"]
     }}
  end

  defp extract_image_output(_), do: :error

  defp persist_rendition(asset, platform, spec, %{storage_key: key} = out, existing) do
    attrs = %{
      asset_id: asset.id,
      platform: platform,
      storage_key: key,
      status: "ready",
      width: out[:width] || spec[:width] || spec["width"],
      height: out[:height],
      format: out[:format] || spec[:format] || spec["format"],
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    result =
      case existing do
        nil ->
          %AssetRendition{} |> AssetRendition.changeset(attrs) |> Repo.insert()

        %AssetRendition{} = row ->
          row |> AssetRendition.changeset(attrs) |> Repo.update()
      end

    case result do
      {:ok, _rendition} -> {:ok, Storage.get_publicUrl(key)}
      {:error, changeset} -> {:error, {:rendition_persist_failed, changeset}}
    end
  end

  # --- video response handling --------------------------------------------

  defp handle_video_response({:ok, %{"jobId" => job_id}}, _asset, _platform)
       when is_binary(job_id) do
    {:ok, {:async, job_id}}
  end

  defp handle_video_response({:ok, %{"storage_key" => key}}, _asset, _platform)
       when is_binary(key) do
    {:ok, Storage.get_publicUrl(key)}
  end

  defp handle_video_response({:ok, body}, _asset, _platform),
    do: {:error, {:unexpected_body, body}}

  defp handle_video_response({:error, _} = err, _asset, _platform), do: err

  # --- helpers -------------------------------------------------------------

  defp primary_url(%ProductAsset{storage_key: key}), do: Storage.get_publicUrl(key)
end
