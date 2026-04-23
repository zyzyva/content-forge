defmodule ContentForge.Jobs.SmsMediaIngestor do
  @moduledoc """
  Oban worker that ingests inbound MMS media attachments from a Twilio
  webhook into R2 as `ProductAsset` rows, then hands each asset off to
  the matching processor (`AssetImageProcessor` / `AssetVideoProcessor`)
  so it runs through the same Media Forge pipeline as a dashboard
  upload.

  The 14.1b webhook enqueues this worker when an inbound event has
  non-empty `media_urls`. The webhook is never blocked on download; it
  returns its TwiML response in milliseconds and the ingest happens
  asynchronously here.

  Per-URL handling (pattern-match on `Twilio.download_media/1` result):

    * `{:ok, %{content_type, binary}}` with an `image/*` or `video/*`
      MIME -upload to R2 under
      `products/<product_id>/assets/<uuid>/sms_<event_id>_<idx>.<ext>`,
      create the `ProductAsset` (uploader = sender phone), enqueue the
      matching processor. On to the next URL.
    * `{:ok, _}` with any other MIME -record an `SmsEvent` audit row
      with `status: "unsupported_media"` and continue to the next URL.
    * `{:error, :not_configured}` -log, record one failed-ingestion
      audit row, return `{:ok, :skipped}` (no retry; config is broken).
    * `{:error, {:transient, _, _}}` -return `{:error, reason}` for
      Oban retry. No audit row; retry will produce terminal audit
      either way.
    * `{:error, {:http_error, _, _}}` /
      `{:error, {:unexpected_status, _, _}}` -record a failed audit
      and cancel (`{:cancel, reason}`). No retry.
    * `{:error, {:media_too_large, _, _}}` -record failed audit and
      cancel; retry won't shrink the asset.
    * Any other `{:error, reason}` -record failed audit and return
      `{:error, reason}` so Oban classifies and retries.
  """
  use Oban.Worker, queue: :content_generation, max_attempts: 3
  require Logger

  alias ContentForge.Jobs.AssetImageProcessor
  alias ContentForge.Jobs.AssetVideoProcessor
  alias ContentForge.ProductAssets
  alias ContentForge.Sms
  alias ContentForge.Sms.SmsEvent
  alias ContentForge.Twilio

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_id" => event_id}}) when is_binary(event_id) do
    event_id
    |> load_event()
    |> ingest()
  end

  # --- load + guard --------------------------------------------------------

  defp load_event(event_id) do
    case ContentForge.Repo.get(SmsEvent, event_id) do
      nil -> {:error, :event_not_found}
      %SmsEvent{} = event -> guard_event(event)
    end
  end

  defp guard_event(%SmsEvent{direction: "inbound", product_id: pid} = event)
       when is_binary(pid) do
    {:ok, event}
  end

  defp guard_event(%SmsEvent{direction: "inbound"}), do: {:error, :no_product_on_event}
  defp guard_event(%SmsEvent{}), do: {:error, :not_inbound_event}

  # --- dispatch entry points ----------------------------------------------

  defp ingest({:error, :event_not_found}) do
    Logger.warning("SmsMediaIngestor: event not found; cancelling")
    {:cancel, "inbound event not found"}
  end

  defp ingest({:error, :no_product_on_event}) do
    Logger.warning("SmsMediaIngestor: event has no product_id; cancelling")
    {:cancel, "inbound event has no product_id (unknown sender)"}
  end

  defp ingest({:error, :not_inbound_event}) do
    Logger.warning("SmsMediaIngestor: event is not inbound; cancelling")
    {:cancel, "event is not inbound"}
  end

  defp ingest({:ok, %SmsEvent{media_urls: urls} = event}) when is_list(urls) do
    process_urls(urls, event, 0, 0)
  end

  # --- per-URL loop -------------------------------------------------------

  defp process_urls([], _event, _index, created), do: {:ok, created}

  defp process_urls([url | rest], event, index, created) do
    url
    |> Twilio.download_media()
    |> handle_download(event, index)
    |> continue_or_halt(rest, event, index, created)
  end

  defp continue_or_halt({:ok, :created}, rest, event, index, created),
    do: process_urls(rest, event, index + 1, created + 1)

  defp continue_or_halt({:ok, :skipped_unsupported}, rest, event, index, created),
    do: process_urls(rest, event, index + 1, created)

  defp continue_or_halt({:ok, :skipped_not_configured}, _rest, _event, _index, _created) do
    {:ok, :skipped}
  end

  defp continue_or_halt({:error, :transient, reason}, _rest, _event, _index, _created),
    do: {:error, reason}

  defp continue_or_halt({:error, :permanent, reason}, _rest, _event, _index, _created),
    do: {:cancel, reason}

  defp continue_or_halt({:error, :unexpected, reason}, _rest, _event, _index, _created),
    do: {:error, reason}

  # --- download result dispatch -------------------------------------------

  defp handle_download({:ok, %{content_type: ct, binary: bin}}, event, index) do
    handle_media(media_type_from(ct), ct, bin, event, index)
  end

  defp handle_download({:error, :not_configured}, event, _index) do
    Logger.warning(
      "SmsMediaIngestor: Twilio unavailable (:not_configured); skipping event #{event.id}"
    )

    {:ok, _} = record_failed_ingest(event, "twilio not configured")
    {:ok, :skipped_not_configured}
  end

  defp handle_download({:error, {:transient, _, _} = reason}, _event, _index) do
    Logger.warning(
      "SmsMediaIngestor: transient download error #{inspect(reason)}; Oban will retry"
    )

    {:error, :transient, reason}
  end

  defp handle_download({:error, {:http_error, status, body}}, event, _index) do
    Logger.error(
      "SmsMediaIngestor: permanent download error #{status} for event #{event.id}: #{inspect(body)}"
    )

    {:ok, _} = record_failed_ingest(event, "http_error #{status}")
    {:error, :permanent, "Twilio media download failed (HTTP #{status})"}
  end

  defp handle_download({:error, {:unexpected_status, status, _body}}, event, _index) do
    Logger.error(
      "SmsMediaIngestor: unexpected status #{status} on download for event #{event.id}"
    )

    {:ok, _} = record_failed_ingest(event, "unexpected_status #{status}")
    {:error, :permanent, "Twilio media download returned unexpected HTTP status #{status}"}
  end

  defp handle_download({:error, {:media_too_large, size, cap}}, event, _index) do
    Logger.error(
      "SmsMediaIngestor: media too large (#{size} > #{cap} bytes) for event #{event.id}"
    )

    {:ok, _} = record_failed_ingest(event, "media_too_large #{size}")
    {:error, :permanent, "Twilio media too large (#{size} > #{cap} bytes)"}
  end

  defp handle_download({:error, reason}, event, _index) do
    Logger.error(
      "SmsMediaIngestor: unexpected download error for event #{event.id}: #{inspect(reason)}"
    )

    {:ok, _} = record_failed_ingest(event, "unexpected #{inspect(reason)}")
    {:error, :unexpected, reason}
  end

  # --- media-type branching ------------------------------------------------

  defp handle_media(nil, content_type, _bin, event, _index) do
    Logger.warning(
      "SmsMediaIngestor: unsupported MIME #{inspect(content_type)} for event #{event.id}"
    )

    {:ok, _} = record_unsupported_media(event, content_type)
    {:ok, :skipped_unsupported}
  end

  defp handle_media("image", content_type, bin, event, index) do
    {:ok, asset} = persist_asset("image", content_type, bin, event, index)
    {:ok, _} = enqueue_processor("image", asset)
    {:ok, :created}
  end

  defp handle_media("video", content_type, bin, event, index) do
    {:ok, asset} = persist_asset("video", content_type, bin, event, index)
    {:ok, _} = enqueue_processor("video", asset)
    {:ok, :created}
  end

  # --- persistence helpers ------------------------------------------------

  defp persist_asset(media_type, content_type, bin, event, index) do
    asset_uuid = Ecto.UUID.generate()
    ext = extension_for(content_type)
    filename = "sms_#{event.id}_#{index}.#{ext}"

    storage_key =
      "products/#{event.product_id}/assets/#{asset_uuid}/#{filename}"

    {:ok, _} = storage_impl().put_object(storage_key, bin, content_type: content_type)

    ProductAssets.create_asset(%{
      product_id: event.product_id,
      storage_key: storage_key,
      filename: filename,
      mime_type: content_type,
      media_type: media_type,
      byte_size: byte_size(bin),
      uploaded_at: DateTime.utc_now(),
      uploader: event.phone_number,
      tags: []
    })
  end

  defp enqueue_processor("image", asset) do
    %{"asset_id" => asset.id}
    |> AssetImageProcessor.new()
    |> Oban.insert()
  end

  defp enqueue_processor("video", asset) do
    %{"asset_id" => asset.id}
    |> AssetVideoProcessor.new()
    |> Oban.insert()
  end

  defp record_unsupported_media(event, content_type) do
    Sms.record_event(%{
      product_id: event.product_id,
      phone_number: event.phone_number,
      direction: "inbound",
      status: "unsupported_media",
      body: "Unsupported media type: #{inspect(content_type)}"
    })
  end

  defp record_failed_ingest(event, reason) do
    Sms.record_event(%{
      product_id: event.product_id,
      phone_number: event.phone_number,
      direction: "inbound",
      status: "failed",
      body: "media ingest failed: #{reason}"
    })
  end

  # --- MIME helpers -------------------------------------------------------

  defp media_type_from(content_type) when is_binary(content_type) do
    cond do
      String.starts_with?(content_type, "image/") -> "image"
      String.starts_with?(content_type, "video/") -> "video"
      true -> nil
    end
  end

  defp media_type_from(_), do: nil

  defp extension_for("image/jpeg"), do: "jpg"
  defp extension_for("image/jpg"), do: "jpg"
  defp extension_for("image/png"), do: "png"
  defp extension_for("image/gif"), do: "gif"
  defp extension_for("image/webp"), do: "webp"
  defp extension_for("image/heic"), do: "heic"
  defp extension_for("image/heif"), do: "heif"
  defp extension_for("video/mp4"), do: "mp4"
  defp extension_for("video/quicktime"), do: "mov"
  defp extension_for("video/x-m4v"), do: "m4v"
  defp extension_for("video/3gpp"), do: "3gp"
  defp extension_for("video/webm"), do: "webm"

  defp extension_for(content_type) when is_binary(content_type) do
    case String.split(content_type, "/", parts: 2) do
      [_type, sub] -> sub |> String.split(";", parts: 2) |> hd()
      _ -> "bin"
    end
  end

  defp extension_for(_), do: "bin"

  defp storage_impl do
    Application.get_env(:content_forge, :asset_storage_impl, ContentForge.Storage)
  end

  # For the ingest audit row we piggyback on the Sms event log; the
  # direction stays "inbound" since these rows describe the inbound
  # media's outcome, not a new outbound message.
  _ = SmsEvent
end
