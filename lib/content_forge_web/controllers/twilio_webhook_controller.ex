defmodule ContentForgeWeb.TwilioWebhookController do
  @moduledoc """
  Receives inbound SMS webhooks from Twilio.

  The `Plugs.TwilioSignatureVerifier` has already validated the HMAC
  signature by the time a request reaches this controller. This action
  dispatches on whether the sender's phone is whitelisted + active for
  any product:

    * Active + whitelisted -records an `"inbound/received"` audit
      event, ensures a `ConversationSession`, returns an empty TwiML
      200 response (Twilio does not auto-reply).
    * Known but deactivated -records a
      `"inbound/rejected_unknown_number"` event with the product_id
      preserved for audit, returns a gated TwiML rejection.
    * Unknown -records a `"inbound/rejected_unknown_number"` event
      with nil product_id, returns the same gated TwiML rejection.

  Malformed payloads (missing `From`) return 400 without recording an
  audit row.

  Downstream routing (OpenClaw / auto-acknowledgement) lands under 14.2.
  """

  use ContentForgeWeb, :controller

  alias ContentForge.Jobs.SmsMediaIngestor
  alias ContentForge.Jobs.SmsReplyDispatcher
  alias ContentForge.Sms
  alias ContentForge.Sms.ProductPhone

  require Logger

  @rejection_body "We don't recognize this number. Please contact the agency to get your number set up."
  @stop_keywords ~w(stop stopall unsubscribe cancel end quit)
  @start_keywords ~w(start unstop)
  @stop_ack_body "You've been unsubscribed from reminders for 7 days. Reply START anytime to resume earlier."
  @start_ack_body "You're opted back in. We'll pick up where we left off."
  @default_pause_days 7

  def receive(conn, %{"From" => from} = params) when is_binary(from) and from != "" do
    body = params["Body"] || ""
    twilio_sid = params["MessageSid"]
    media_urls = extract_media_urls(params)

    from
    |> Sms.lookup_phone_by_number()
    |> dispatch(conn, from, body, media_urls, twilio_sid)
  end

  def receive(conn, _params) do
    Logger.warning("TwilioWebhook: malformed payload (missing From)")

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(400, "missing From parameter")
  end

  # --- dispatch by lookup result ------------------------------------------

  defp dispatch(%ProductPhone{active: true} = phone, conn, from, body, media, sid) do
    dispatch_active(body_intent(body), phone, conn, from, body, media, sid)
  end

  defp dispatch(%ProductPhone{active: false} = phone, conn, from, body, media, sid) do
    {:ok, _event} =
      Sms.record_event(%{
        product_id: phone.product_id,
        phone_number: from,
        direction: "inbound",
        status: "rejected_unknown_number",
        body: body,
        media_urls: media,
        twilio_sid: sid
      })

    rejection_twiml(conn)
  end

  defp dispatch(nil, conn, from, body, media, sid) do
    {:ok, _event} =
      Sms.record_event(%{
        phone_number: from,
        direction: "inbound",
        status: "rejected_unknown_number",
        body: body,
        media_urls: media,
        twilio_sid: sid
      })

    rejection_twiml(conn)
  end

  # --- active-phone intent dispatch ---------------------------------------

  defp body_intent(body) when is_binary(body) do
    normalized = body |> String.trim() |> String.downcase()

    cond do
      normalized in @stop_keywords -> :stop
      normalized in @start_keywords -> :start
      true -> :normal
    end
  end

  defp body_intent(_), do: :normal

  defp dispatch_active(:stop, phone, conn, from, body, media, sid) do
    {:ok, _event} =
      Sms.record_event(%{
        product_id: phone.product_id,
        phone_number: from,
        direction: "inbound",
        status: "stop_received",
        body: body,
        media_urls: media,
        twilio_sid: sid
      })

    {:ok, _} = Sms.pause_phone_reminders(phone, @default_pause_days)

    ack_twiml(conn, @stop_ack_body)
  end

  defp dispatch_active(:start, phone, conn, from, body, media, sid) do
    {:ok, _} = Sms.resume_phone_reminders(phone)

    {:ok, event} =
      Sms.record_event(%{
        product_id: phone.product_id,
        phone_number: from,
        direction: "inbound",
        status: "start_received",
        body: body,
        media_urls: media,
        twilio_sid: sid
      })

    {:ok, _session} = Sms.get_or_start_session(phone.product_id, from)

    # Normal auto-reply continues so the conversation keeps going.
    {:ok, _job} =
      %{"event_id" => event.id}
      |> SmsReplyDispatcher.new()
      |> Oban.insert()

    enqueue_media_ingest(event, media)

    ack_twiml(conn, @start_ack_body)
  end

  defp dispatch_active(:normal, phone, conn, from, body, media, sid) do
    {:ok, event} =
      Sms.record_event(%{
        product_id: phone.product_id,
        phone_number: from,
        direction: "inbound",
        status: "received",
        body: body,
        media_urls: media,
        twilio_sid: sid
      })

    {:ok, _session} = Sms.get_or_start_session(phone.product_id, from)

    {:ok, _job} =
      %{"event_id" => event.id}
      |> SmsReplyDispatcher.new()
      |> Oban.insert()

    enqueue_media_ingest(event, media)

    empty_twiml(conn)
  end

  # --- media-ingest enqueue -----------------------------------------------

  defp enqueue_media_ingest(_event, []), do: :ok

  defp enqueue_media_ingest(event, media) when is_list(media) do
    {:ok, _job} =
      %{"event_id" => event.id}
      |> SmsMediaIngestor.new()
      |> Oban.insert()

    :ok
  end

  # --- TwiML helpers ------------------------------------------------------

  defp empty_twiml(conn) do
    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Response></Response>")
  end

  defp rejection_twiml(conn) do
    ack_twiml(conn, @rejection_body)
  end

  defp ack_twiml(conn, message) do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Response>
      <Message>#{message}</Message>
    </Response>
    """

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, xml)
  end

  defp extract_media_urls(params) do
    num_media = params |> Map.get("NumMedia", "0") |> parse_int()

    0..max(num_media - 1, -1)//1
    |> Enum.reduce([], fn idx, acc ->
      case params["MediaUrl#{idx}"] do
        url when is_binary(url) and url != "" -> [url | acc]
        _ -> acc
      end
    end)
    |> Enum.reverse()
  end

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_int(_), do: 0
end
