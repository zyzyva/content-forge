defmodule ContentForge.Jobs.ReminderDispatcher do
  @moduledoc """
  Oban worker that sends a single reminder SMS to one product phone.

  Enqueued by `ContentForge.Jobs.ReminderScheduler` when a phone's
  cadence has elapsed, the phone is not paused, and the current local
  hour is inside the product's allowed window.

  ## Composition

  Reminder text is selected by `ContentForge.Sms.consecutive_ignored_reminders/2`:

    * count == 0 → friendly check-in ("Hey - checking in, no response
      needed unless you've got an update.")
    * count < stop_after_ignored but >= backoff_after_ignored → gentler
      follow-up ("Still here when you're ready to circle back...")
    * count >= stop_after_ignored → stop-notify (last message, we
      won't send another reminder until you reply)

  OpenClaw branch is wired but ships the fallback text today (mirrors
  14.2b). Real AI-crafted reminder text lands under 14.2c.

  ## Failure modes (mirroring `SmsReplyDispatcher` taxonomy)

    * `{:ok, :sent}` - normal send, outbound `"sent"` audit row
    * `{:ok, :stop_notify}` - same as `:sent` but tagged so caller
      tests can assert the stop branch fired
    * `{:ok, :paused}` - phone was paused by STOP between schedule and
      dispatch; no Twilio call, no audit row
    * `{:ok, :twilio_not_configured}` - record `"failed"` audit, no
      retry
    * `{:error, {:transient, _, _}}` - Oban retry, no audit row
    * `{:cancel, reason}` - permanent Twilio error, audit row with
      `"failed"`
  """
  use Oban.Worker, queue: :default, max_attempts: 3
  require Logger

  alias ContentForge.Sms
  alias ContentForge.Sms.ProductPhone
  alias ContentForge.Sms.ReminderConfig
  alias ContentForge.Twilio

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"phone_id" => phone_id, "product_id" => product_id}
      })
      when is_binary(phone_id) and is_binary(product_id) do
    phone_id
    |> load_phone()
    |> dispatch(product_id)
  end

  defp load_phone(phone_id) do
    case ContentForge.Repo.get(ProductPhone, phone_id) do
      nil -> {:error, :phone_not_found}
      %ProductPhone{} = phone -> {:ok, phone}
    end
  end

  defp dispatch({:error, :phone_not_found}, _product_id) do
    Logger.warning("ReminderDispatcher: phone not found; cancelling")
    {:cancel, "phone not found"}
  end

  defp dispatch({:ok, %ProductPhone{} = phone}, product_id) do
    ensure_not_paused(phone, product_id, DateTime.utc_now())
  end

  defp ensure_not_paused(%ProductPhone{reminders_paused_until: until} = phone, product_id, now) do
    if paused?(until, now) do
      Logger.info("ReminderDispatcher: phone #{phone.phone_number} paused; skipping")
      {:ok, :paused}
    else
      send_reminder(phone, product_id)
    end
  end

  defp paused?(nil, _now), do: false
  defp paused?(%DateTime{} = until, now), do: DateTime.compare(until, now) == :gt

  defp send_reminder(%ProductPhone{} = phone, product_id) do
    config = Sms.get_reminder_config(product_id)
    count = Sms.consecutive_ignored_reminders(product_id, phone.phone_number)
    {intent, text} = compose(count, config, phone, product_id)

    text
    |> send_via_twilio(phone)
    |> handle_twilio_result(phone, product_id, text, intent)
  end

  # --- composition --------------------------------------------------------

  # Three heads. Order matters: stop threshold wins over backoff which
  # wins over friendly. `intent` is only :stop_notify for the stop head
  # so callers can tell whether we just crossed the line.
  defp compose(count, %ReminderConfig{stop_after_ignored: stop} = config, phone, product_id)
       when count >= stop do
    {:stop_notify, stop_text(config, phone, product_id, count)}
  end

  defp compose(count, %ReminderConfig{backoff_after_ignored: backoff} = config, phone, product_id)
       when count >= backoff do
    {:gentler, gentler_text(config, phone, product_id, count)}
  end

  defp compose(count, config, phone, product_id),
    do: {:friendly, friendly_text(config, phone, product_id, count)}

  defp friendly_text(_config, _phone, _product_id, _count) do
    "Hey - checking in, no response needed unless you've got an update."
  end

  defp gentler_text(_config, _phone, _product_id, _count) do
    "Just wanted to circle back on the last couple messages. Reply anytime, no pressure."
  end

  defp stop_text(_config, _phone, _product_id, _count) do
    "Last note from us - we won't send further reminders. Reply START anytime to resume."
  end

  # --- Twilio dispatch ----------------------------------------------------

  defp send_via_twilio(text, %ProductPhone{phone_number: to}) do
    Twilio.send_sms(to, text)
  end

  defp handle_twilio_result({:ok, %{sid: sid, status: status}}, phone, product_id, text, intent) do
    {:ok, _} =
      Sms.record_event(%{
        product_id: product_id,
        phone_number: phone.phone_number,
        direction: "outbound",
        status: "sent",
        body: text,
        twilio_sid: sid
      })

    Logger.info(
      "ReminderDispatcher: sent #{intent} to #{phone.phone_number} (sid=#{sid}, status=#{status})"
    )

    outcome_for(intent)
  end

  defp handle_twilio_result({:error, :not_configured}, phone, product_id, text, _intent) do
    {:ok, _} = record_failed(product_id, phone, text)
    Logger.warning("ReminderDispatcher: Twilio unavailable (:not_configured); skipping retry")
    {:ok, :twilio_not_configured}
  end

  defp handle_twilio_result(
         {:error, {:transient, _, _} = reason},
         _phone,
         _product_id,
         _text,
         _intent
       ) do
    Logger.warning(
      "ReminderDispatcher: transient Twilio error #{inspect(reason)}; Oban will retry"
    )

    {:error, reason}
  end

  defp handle_twilio_result(
         {:error, {:http_error, status, body}},
         phone,
         product_id,
         text,
         _intent
       ) do
    Logger.error(
      "ReminderDispatcher: permanent Twilio error #{status} for #{phone.phone_number}: #{inspect(body)}"
    )

    {:ok, _} = record_failed(product_id, phone, text)
    {:cancel, "Twilio rejected send (HTTP #{status})"}
  end

  defp handle_twilio_result(
         {:error, {:unexpected_status, status, _body}},
         phone,
         product_id,
         text,
         _intent
       ) do
    Logger.error(
      "ReminderDispatcher: Twilio returned unexpected HTTP status #{status} for #{phone.phone_number}"
    )

    {:ok, _} = record_failed(product_id, phone, text)
    {:cancel, "Twilio returned unexpected HTTP status #{status}"}
  end

  defp handle_twilio_result({:error, reason}, phone, product_id, text, _intent) do
    Logger.error(
      "ReminderDispatcher: unexpected Twilio error for #{phone.phone_number}: #{inspect(reason)}"
    )

    {:ok, _} = record_failed(product_id, phone, text)
    {:error, reason}
  end

  defp outcome_for(:stop_notify), do: {:ok, :stop_notify}
  defp outcome_for(_), do: {:ok, :sent}

  defp record_failed(product_id, phone, text) do
    Sms.record_event(%{
      product_id: product_id,
      phone_number: phone.phone_number,
      direction: "outbound",
      status: "failed",
      body: text
    })
  end

  @impl Oban.Worker
  def timeout(_job), do: 30_000
end
