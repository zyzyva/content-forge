defmodule ContentForge.Jobs.AssetVideoProcessor do
  @moduledoc """
  Oban worker that routes a pending `ProductAsset` (video) through Media
  Forge for probe, normalization to H.264/AAC, and poster-frame
  generation.

  Flow mirrors `ContentForge.Jobs.AssetImageProcessor`:

    1. Loads the asset. Missing, non-`pending`, or missing-storage-key
       assets short-circuit; no HTTP is issued.
    2. Calls `ContentForge.MediaForge.enqueue_video_normalize/1` with the
       original storage key and the transform request (probe, normalize
       to H.264/AAC, poster frame).
    3. Synchronous responses carrying `duration_ms`/`width`/`height`/
       a normalized-video storage key / a poster-image storage key are
       persisted immediately via `ProductAssets.mark_processed/2`.
    4. Asynchronous responses returning a `jobId` are resolved by polling
       `MediaForge.get_job/1` with a configurable interval and attempt
       cap (defaults to 3 seconds x 60 attempts; tests override to 0).

  Downgrade and error rules match 13.1d exactly:

    * `{:error, :not_configured}` marks the asset failed with
      `"media_forge_unavailable"`.
    * Transient errors (5xx, 429, timeout, network) return
      `{:error, reason}` so Oban retries; `mark_processed/2` is an
      upsert so retries are idempotent.
    * Permanent errors (4xx, unexpected_status) mark the asset failed
      and return `{:cancel, reason}`.

  The poster storage key is persisted to `thumbnail_storage_key` on the
  asset row (same schema field image assets use for their thumbnail);
  the encoded-video storage key is persisted to the new
  `normalized_storage_key` field. Keeping image thumbnails and video
  posters on the same column means a single dashboard lookup can drive
  preview rendering for both media types.
  """

  use Oban.Worker, queue: :content_generation, max_attempts: 3

  alias ContentForge.MediaForge
  alias ContentForge.ProductAssets
  alias ContentForge.ProductAssets.ProductAsset

  require Logger

  @default_poll_interval_ms 3_000
  @default_poll_max_attempts 60

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"asset_id" => asset_id}}) do
    case ProductAssets.get_asset(asset_id) do
      nil ->
        Logger.warning("AssetVideoProcessor: asset #{asset_id} not found; cancelling")
        {:cancel, "asset not found"}

      asset ->
        process(asset)
    end
  end

  # --- main flow ------------------------------------------------------------

  defp process(%ProductAsset{status: status} = asset) when status != "pending" do
    Logger.info(
      "AssetVideoProcessor: asset #{asset.id} already #{status}; skipping re-processing"
    )

    :ok
  end

  defp process(%ProductAsset{storage_key: nil} = asset) do
    fail(asset, "asset has no storage_key")
  end

  defp process(%ProductAsset{} = asset) do
    request = %{
      source_key: asset.storage_key,
      transforms: ["probe", "normalize", "poster"],
      normalize: %{video_codec: "h264", audio_codec: "aac"},
      poster: %{max_dimension: 480},
      metadata: %{asset_id: asset.id, product_id: asset.product_id}
    }

    request
    |> MediaForge.enqueue_video_normalize()
    |> handle_response(asset)
  end

  # --- response handling ---------------------------------------------------

  defp handle_response({:ok, body}, asset) when is_map(body) do
    case {extract_result(body), body["jobId"]} do
      {result, _} when is_map(result) ->
        apply_result(asset, result)

      {_, job_id} when is_binary(job_id) ->
        Logger.info("AssetVideoProcessor: asset #{asset.id} awaiting Media Forge job #{job_id}")

        poll_until_done(job_id, asset, poll_max_attempts())

      _ ->
        fail(asset, "Media Forge returned an unrecognized response")
    end
  end

  defp handle_response({:error, :not_configured}, asset) do
    fail(asset, "media_forge_unavailable")
  end

  defp handle_response({:error, {:http_error, status, body}}, asset) do
    Logger.error(
      "AssetVideoProcessor: asset #{asset.id} permanent Media Forge error #{status} #{inspect(body)}"
    )

    fail(asset, "Media Forge rejected request (HTTP #{status})")
  end

  defp handle_response({:error, {:unexpected_status, status, _body}}, asset) do
    fail(asset, "Media Forge returned unexpected HTTP status #{status}")
  end

  defp handle_response({:error, {:transient, _, _} = reason}, asset) do
    Logger.warning(
      "AssetVideoProcessor: asset #{asset.id} transient Media Forge error #{inspect(reason)}; Oban will retry"
    )

    {:error, reason}
  end

  defp handle_response({:error, reason}, asset) do
    Logger.error(
      "AssetVideoProcessor: asset #{asset.id} unexpected Media Forge error #{inspect(reason)}"
    )

    {:error, reason}
  end

  # --- polling -------------------------------------------------------------

  defp poll_until_done(_job_id, asset, 0) do
    fail(asset, "Media Forge video job polling timeout")
  end

  defp poll_until_done(job_id, asset, attempts_left) do
    job_id
    |> MediaForge.get_job()
    |> handle_poll(job_id, asset, attempts_left)
  end

  defp handle_poll({:ok, %{"status" => status} = body}, _job_id, asset, _attempts)
       when status in ["done", "completed", "succeeded"] do
    case extract_result(body) do
      nil -> fail(asset, "Media Forge reported done without a result")
      result -> apply_result(asset, result)
    end
  end

  defp handle_poll({:ok, %{"status" => status} = body}, _job_id, asset, _attempts)
       when status in ["failed", "error"] do
    reason = body["error"] || body["message"] || "unknown"

    Logger.error(
      "AssetVideoProcessor: asset #{asset.id} Media Forge video job failed: #{inspect(reason)}"
    )

    fail(asset, "Media Forge video job failed: #{inspect(reason)}")
  end

  defp handle_poll({:ok, _body}, job_id, asset, attempts_left) do
    Process.sleep(poll_interval_ms())
    poll_until_done(job_id, asset, attempts_left - 1)
  end

  defp handle_poll({:error, :not_configured}, _job_id, asset, _attempts) do
    fail(asset, "media_forge_unavailable")
  end

  defp handle_poll({:error, {:transient, _, _} = reason}, _job_id, asset, _attempts) do
    Logger.warning(
      "AssetVideoProcessor: asset #{asset.id} poll transient error #{inspect(reason)}; Oban will retry"
    )

    {:error, reason}
  end

  defp handle_poll({:error, reason}, _job_id, asset, _attempts) do
    Logger.error("AssetVideoProcessor: asset #{asset.id} poll failed: #{inspect(reason)}")

    {:error, reason}
  end

  # --- persistence --------------------------------------------------------

  defp apply_result(asset, result) when is_map(result) do
    attrs = %{
      width: extract_int(result, ["width", "video_width"]),
      height: extract_int(result, ["height", "video_height"]),
      duration_ms:
        extract_int(result, ["duration_ms", "duration_millis"]) ||
          duration_from_seconds(result),
      thumbnail_storage_key:
        first_present(result, ["poster_storage_key", "poster_key", "thumbnail_storage_key"]),
      normalized_storage_key:
        first_present(result, [
          "normalized_storage_key",
          "output_storage_key",
          "output_key",
          "r2_key"
        ])
    }

    case ProductAssets.mark_processed(asset, attrs) do
      {:ok, updated} ->
        Logger.info(
          "AssetVideoProcessor: asset #{asset.id} processed (#{attrs.width}x#{attrs.height}, #{attrs.duration_ms}ms, normalized=#{attrs.normalized_storage_key}, poster=#{attrs.thumbnail_storage_key})"
        )

        {:ok, updated}

      {:error, changeset} ->
        Logger.error(
          "AssetVideoProcessor: failed to mark asset #{asset.id} processed: #{inspect(changeset.errors)}"
        )

        fail(asset, "invalid processing result")
    end
  end

  defp fail(asset, reason) do
    Logger.warning("AssetVideoProcessor: marking asset #{asset.id} failed: #{reason}")
    {:ok, _} = ProductAssets.mark_failed(asset, reason)
    {:cancel, reason}
  end

  # --- result extraction --------------------------------------------------

  defp extract_result(%{"result" => result}) when is_map(result), do: result
  defp extract_result(%{"data" => result}) when is_map(result), do: result

  defp extract_result(body)
       when is_map_key(body, "duration_ms") or is_map_key(body, "normalized_storage_key") or
              is_map_key(body, "output_storage_key"),
       do: body

  defp extract_result(_), do: nil

  defp extract_int(map, keys), do: integer_value(first_present(map, keys))

  defp integer_value(n) when is_integer(n), do: n
  defp integer_value(n) when is_float(n), do: trunc(n)

  defp integer_value(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp integer_value(_), do: nil

  defp duration_from_seconds(result) do
    case first_present(result, ["duration_seconds", "duration"]) do
      n when is_number(n) -> trunc(n * 1000)
      _ -> nil
    end
  end

  defp first_present(_map, []), do: nil

  defp first_present(map, [key | rest]) do
    case map[key] do
      nil -> first_present(map, rest)
      "" -> first_present(map, rest)
      value -> value
    end
  end

  # --- config -------------------------------------------------------------

  defp poll_interval_ms do
    get_config(:poll_interval_ms, @default_poll_interval_ms)
  end

  defp poll_max_attempts do
    get_config(:poll_max_attempts, @default_poll_max_attempts)
  end

  defp get_config(key, default) do
    :content_forge
    |> Application.get_env(:asset_video_processor, [])
    |> Keyword.get(key, default)
  end
end
