defmodule ContentForge.Jobs.AssetImageProcessor do
  @moduledoc """
  Oban worker that routes a pending `ProductAsset` (image) through Media
  Forge for autorotate, EXIF strip, thumbnail generation, and dimension
  probing.

  Flow:

    1. Loads the asset. If it is not `pending` or has no `storage_key`,
       the job returns `:ok` without issuing HTTP (idempotency: a
       re-run of a job for an already-processed asset is a no-op).
    2. Calls `ContentForge.MediaForge.enqueue_image_process/1` with the
       original storage key and the transform request (autorotate, strip
       EXIF, thumbnail, probe).
    3. Synchronous responses carrying `width`/`height`/`thumbnail_storage_key`
       are persisted immediately via `ProductAssets.mark_processed/2`.
    4. Asynchronous responses returning a `jobId` are resolved by polling
       `MediaForge.get_job/1` with a configurable interval and attempt
       cap (defaults to 3 seconds x 60 attempts; tests override to 0).

  Downgrade and error rules:

    * `{:error, :not_configured}` marks the asset failed with
      `"media_forge_unavailable"` so the dashboard surfaces it instead
      of leaving it in `pending`. No synthetic dimensions or thumbnail
      are fabricated.
    * Transient errors (5xx, 429, timeout, network) return
      `{:error, reason}` so Oban retries the whole job. The
      `mark_processed/2` upsert makes retries idempotent.
    * Permanent errors (4xx, unexpected_status) mark the asset failed
      with the error recorded and return `{:cancel, reason}` so Oban
      does not retry against unchanged input.
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
        Logger.warning("AssetImageProcessor: asset #{asset_id} not found; cancelling")
        {:cancel, "asset not found"}

      asset ->
        process(asset)
    end
  end

  # --- main flow ------------------------------------------------------------

  defp process(%ProductAsset{status: status} = asset) when status != "pending" do
    Logger.info(
      "AssetImageProcessor: asset #{asset.id} already #{status}; skipping re-processing"
    )

    :ok
  end

  defp process(%ProductAsset{storage_key: nil} = asset) do
    fail(asset, "asset has no storage_key")
  end

  defp process(%ProductAsset{} = asset) do
    request = %{
      source_key: asset.storage_key,
      transforms: ["autorotate", "strip_exif", "thumbnail", "probe"],
      thumbnail: %{max_dimension: 480},
      metadata: %{asset_id: asset.id, product_id: asset.product_id}
    }

    request
    |> MediaForge.enqueue_image_process()
    |> handle_response(asset)
  end

  # --- response handling ---------------------------------------------------

  defp handle_response({:ok, body}, asset) when is_map(body) do
    case {extract_result(body), body["jobId"]} do
      {result, _} when is_map(result) ->
        apply_result(asset, result)

      {_, job_id} when is_binary(job_id) ->
        Logger.info("AssetImageProcessor: asset #{asset.id} awaiting Media Forge job #{job_id}")

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
      "AssetImageProcessor: asset #{asset.id} permanent Media Forge error #{status} #{inspect(body)}"
    )

    fail(asset, "Media Forge rejected request (HTTP #{status})")
  end

  defp handle_response({:error, {:unexpected_status, status, _body}}, asset) do
    fail(asset, "Media Forge returned unexpected HTTP status #{status}")
  end

  defp handle_response({:error, {:transient, _, _} = reason}, asset) do
    Logger.warning(
      "AssetImageProcessor: asset #{asset.id} transient Media Forge error #{inspect(reason)}; Oban will retry"
    )

    {:error, reason}
  end

  defp handle_response({:error, reason}, asset) do
    Logger.error(
      "AssetImageProcessor: asset #{asset.id} unexpected Media Forge error #{inspect(reason)}"
    )

    {:error, reason}
  end

  # --- polling -------------------------------------------------------------

  defp poll_until_done(_job_id, asset, 0) do
    fail(asset, "Media Forge image job polling timeout")
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
      "AssetImageProcessor: asset #{asset.id} Media Forge image job failed: #{inspect(reason)}"
    )

    fail(asset, "Media Forge image job failed: #{inspect(reason)}")
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
      "AssetImageProcessor: asset #{asset.id} poll transient error #{inspect(reason)}; Oban will retry"
    )

    {:error, reason}
  end

  defp handle_poll({:error, reason}, _job_id, asset, _attempts) do
    Logger.error("AssetImageProcessor: asset #{asset.id} poll failed: #{inspect(reason)}")

    {:error, reason}
  end

  # --- persistence --------------------------------------------------------

  defp apply_result(asset, result) when is_map(result) do
    attrs = %{
      width: extract_int(result, ["width", "image_width"]),
      height: extract_int(result, ["height", "image_height"]),
      thumbnail_storage_key:
        first_present(result, ["thumbnail_storage_key", "thumbnail_key", "thumbnail_url"])
    }

    case ProductAssets.mark_processed(asset, attrs) do
      {:ok, updated} ->
        Logger.info(
          "AssetImageProcessor: asset #{asset.id} processed (#{attrs.width}x#{attrs.height}, thumb=#{attrs.thumbnail_storage_key})"
        )

        {:ok, updated}

      {:error, changeset} ->
        Logger.error(
          "AssetImageProcessor: failed to mark asset #{asset.id} processed: #{inspect(changeset.errors)}"
        )

        fail(asset, "invalid processing result")
    end
  end

  defp fail(asset, reason) do
    Logger.warning("AssetImageProcessor: marking asset #{asset.id} failed: #{reason}")
    {:ok, _} = ProductAssets.mark_failed(asset, reason)
    {:cancel, reason}
  end

  # --- result extraction --------------------------------------------------

  defp extract_result(%{"result" => result}) when is_map(result), do: result
  defp extract_result(%{"data" => result}) when is_map(result), do: result

  defp extract_result(body) when is_map_key(body, "width") and is_map_key(body, "height"),
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
    |> Application.get_env(:asset_image_processor, [])
    |> Keyword.get(key, default)
  end
end
