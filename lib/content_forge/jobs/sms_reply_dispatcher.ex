defmodule ContentForge.Jobs.SmsReplyDispatcher do
  @moduledoc """
  Oban worker that dispatches an auto-reply to a whitelisted inbound
  `SmsEvent`.

  The 14.1b webhook enqueues this worker after recording the inbound
  event and starting the conversation session. The worker:

    1. Loads the inbound event. Skips with `{:cancel, ...}` if the
       event is missing, is outbound, or has a nil `product_id`
       (rejected unknown-sender rows never get an auto-reply).
    2. Enforces a per-phone daily rate limit (default 10 outbound /
       phone / 24h, configurable via
       `:content_forge, :sms, :outbound_rate_limit_per_day`). Over
       the limit: records a `rejected_rate_limit` outbound audit row
       and exits `{:ok, :rate_limited}` without touching Twilio.
    3. Checks whether OpenClaw is configured
       (`:content_forge, :open_claw, :base_url`). **Both branches
       ship the unavailable fallback in this slice** - the real
       OpenClaw reply-generation call is deferred to 14.2c. This
       guarantees no synthetic reply enters production regardless of
       config state.
    4. Resolves the fallback text:
       `product.publishing_targets["sms"]["unavailable_fallback"]`
       if set; otherwise a hard-coded default.
    5. Calls `ContentForge.Twilio.send_sms/3`.

  Failure modes:

    * `{:ok, %{sid, status}}` from Twilio -records an outbound
      `"sent"` audit row with the SID + text, returns
      `{:ok, :unavailable_fallback}`.
    * `{:error, :not_configured}` from Twilio -records an outbound
      `"failed"` audit row with the body, logs "Twilio unavailable",
      returns `{:ok, :twilio_not_configured}` (no crash, no retry -
      the config is broken, retrying won't fix it).
    * `{:error, {:transient, _, _}}` -returns `{:error, reason}` so
      Oban retries; no audit row is written (retry will produce one
      on success, or terminal cancel).
    * `{:error, {:http_error, _, _}}` or
      `{:unexpected_status, _, _}` -records an outbound `"failed"`
      audit row, returns `{:cancel, reason}`.
    * Other errors -records a `"failed"` audit row and returns
      `{:error, reason}` so Oban classifies and retries.

  The `ConversationSession` is left untouched by this slice; state
  transitions driven by real reply content are 14.2c territory.
  """
  use Oban.Worker, queue: :default, max_attempts: 3
  require Logger

  alias ContentForge.Products
  alias ContentForge.Sms
  alias ContentForge.Sms.SmsEvent
  alias ContentForge.Twilio

  @default_fallback "Thanks — your assistant is temporarily unavailable. We will get back to you shortly."
  @default_rate_limit 10

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_id" => event_id}}) when is_binary(event_id) do
    event_id
    |> load_event()
    |> dispatch_or_skip()
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

  defp dispatch_or_skip({:error, :event_not_found}) do
    Logger.warning("SmsReplyDispatcher: event not found; cancelling")
    {:cancel, "inbound event not found"}
  end

  defp dispatch_or_skip({:error, :no_product_on_event}) do
    Logger.warning("SmsReplyDispatcher: event has no product_id; cancelling")
    {:cancel, "inbound event has no product_id (unknown sender)"}
  end

  defp dispatch_or_skip({:error, :not_inbound_event}) do
    Logger.warning("SmsReplyDispatcher: event is not inbound; cancelling")
    {:cancel, "event is not inbound"}
  end

  defp dispatch_or_skip({:ok, event}) do
    product = Products.get_product!(event.product_id)
    dispatch_with_quota(event, product)
  end

  # --- rate limit ----------------------------------------------------------

  defp dispatch_with_quota(event, product) do
    limit = rate_limit()
    count = Sms.count_recent_outbound(event.phone_number)
    enforce_quota(count >= limit, count, limit, event, product)
  end

  defp enforce_quota(true, count, limit, event, _product) do
    Logger.warning(
      "SmsReplyDispatcher: rate-limit hit for #{event.phone_number} (#{count}/#{limit}); skipping Twilio"
    )

    {:ok, _} = record_rate_limit_rejection(event)
    {:ok, :rate_limited}
  end

  defp enforce_quota(false, _count, _limit, event, product), do: send_fallback(event, product)

  defp record_rate_limit_rejection(event) do
    Sms.record_event(%{
      product_id: event.product_id,
      phone_number: event.phone_number,
      direction: "outbound",
      status: "rejected_rate_limit",
      body: nil
    })
  end

  defp rate_limit do
    Application.get_env(:content_forge, :sms, [])
    |> Keyword.get(:outbound_rate_limit_per_day, @default_rate_limit)
  end

  # --- send fallback -------------------------------------------------------

  defp send_fallback(event, product) do
    text = resolve_fallback_text(product)

    text
    |> send_via_twilio(event)
    |> handle_twilio_result(event, text)
  end

  defp resolve_fallback_text(%Products.Product{
         publishing_targets: %{"sms" => %{"unavailable_fallback" => text}}
       })
       when is_binary(text) and text != "",
       do: text

  defp resolve_fallback_text(_), do: @default_fallback

  defp send_via_twilio(text, event) do
    Twilio.send_sms(event.phone_number, text)
  end

  # --- Twilio result dispatch ---------------------------------------------

  defp handle_twilio_result({:ok, %{sid: sid, status: status}}, event, text) do
    {:ok, _} =
      Sms.record_event(%{
        product_id: event.product_id,
        phone_number: event.phone_number,
        direction: "outbound",
        status: "sent",
        body: text,
        twilio_sid: sid
      })

    Logger.info(
      "SmsReplyDispatcher: sent unavailable fallback to #{event.phone_number} (sid=#{sid}, status=#{status})"
    )

    {:ok, :unavailable_fallback}
  end

  defp handle_twilio_result({:error, :not_configured}, event, text) do
    {:ok, _} = record_failed_outbound(event, text)
    Logger.warning("SmsReplyDispatcher: Twilio unavailable (:not_configured); skipping retry")
    {:ok, :twilio_not_configured}
  end

  defp handle_twilio_result({:error, {:transient, _, _} = reason}, _event, _text) do
    Logger.warning(
      "SmsReplyDispatcher: transient Twilio error #{inspect(reason)}; Oban will retry"
    )

    {:error, reason}
  end

  defp handle_twilio_result({:error, {:http_error, status, body}}, event, text) do
    Logger.error(
      "SmsReplyDispatcher: permanent Twilio error #{status} for #{event.phone_number}: #{inspect(body)}"
    )

    {:ok, _} = record_failed_outbound(event, text)
    {:cancel, "Twilio rejected send (HTTP #{status})"}
  end

  defp handle_twilio_result({:error, {:unexpected_status, status, _body}}, event, text) do
    Logger.error(
      "SmsReplyDispatcher: Twilio returned unexpected HTTP status #{status} for #{event.phone_number}"
    )

    {:ok, _} = record_failed_outbound(event, text)
    {:cancel, "Twilio returned unexpected HTTP status #{status}"}
  end

  defp handle_twilio_result({:error, reason}, event, text) do
    Logger.error(
      "SmsReplyDispatcher: unexpected Twilio error for #{event.phone_number}: #{inspect(reason)}"
    )

    {:ok, _} = record_failed_outbound(event, text)
    {:error, reason}
  end

  defp record_failed_outbound(event, text) do
    Sms.record_event(%{
      product_id: event.product_id,
      phone_number: event.phone_number,
      direction: "outbound",
      status: "failed",
      body: text
    })
  end
end
