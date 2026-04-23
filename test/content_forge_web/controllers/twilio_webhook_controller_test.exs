defmodule ContentForgeWeb.TwilioWebhookControllerTest do
  use ContentForgeWeb.ConnCase, async: false
  use Oban.Testing, repo: ContentForge.Repo

  import ExUnit.CaptureLog

  alias ContentForge.Jobs.SmsMediaIngestor
  alias ContentForge.Jobs.SmsReplyDispatcher
  alias ContentForge.Products
  alias ContentForge.Repo
  alias ContentForge.Sms
  alias ContentForge.Sms.ConversationSession
  alias ContentForge.Sms.SmsEvent

  @auth_token "twilio-test-auth-token"
  @webhook_path "/webhooks/twilio/sms"
  @twilio_config_key :twilio

  setup %{conn: conn} do
    original = Application.get_env(:content_forge, @twilio_config_key, [])

    on_exit(fn ->
      Application.put_env(:content_forge, @twilio_config_key, original)
    end)

    Application.put_env(:content_forge, @twilio_config_key, auth_token: @auth_token)

    {:ok, product} =
      Products.create_product(%{name: "Twilio Product", voice_profile: "professional"})

    %{conn: conn, product: product}
  end

  # Twilio signature: base64(HMAC-SHA1(auth_token, url + concat(sorted(key+value))))
  defp sign(url, params, token \\ @auth_token) do
    sorted =
      params
      |> Enum.sort_by(fn {k, _} -> to_string(k) end)
      |> Enum.map_join(fn {k, v} -> to_string(k) <> to_string(v) end)

    :crypto.mac(:hmac, :sha, token, url <> sorted)
    |> Base.encode64()
  end

  defp webhook_url(conn), do: "http://#{conn.host}#{@webhook_path}"

  defp post_signed(conn, params, overrides \\ []) do
    url = Keyword.get(overrides, :url, webhook_url(conn))
    signature = Keyword.get(overrides, :signature, sign(url, params))

    conn
    |> Plug.Conn.put_req_header("x-twilio-signature", signature)
    |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post(@webhook_path, params)
  end

  describe "signed inbound from a whitelisted active phone" do
    test "records the event, starts a session, and returns 200 empty TwiML",
         %{conn: conn, product: product} do
      {:ok, _phone} =
        Sms.create_phone(%{
          product_id: product.id,
          phone_number: "+15551112222",
          role: "owner"
        })

      params = %{
        "From" => "+15551112222",
        "To" => "+15557654321",
        "Body" => "hello from the product owner",
        "NumMedia" => "0",
        "MessageSid" => "SMabc123"
      }

      conn = post_signed(conn, params)

      assert conn.status == 200
      assert response_content_type(conn, :xml) =~ "xml"
      assert response(conn, 200) =~ "<Response"

      assert [event] = Repo.all(SmsEvent)
      assert event.direction == "inbound"
      assert event.status == "received"
      assert event.phone_number == "+15551112222"
      assert event.body == "hello from the product owner"
      assert event.twilio_sid == "SMabc123"
      assert event.product_id == product.id

      assert [session] = Repo.all(ConversationSession)
      assert session.product_id == product.id
      assert session.phone_number == "+15551112222"
      assert session.state == "idle"

      assert_enqueued(
        worker: SmsReplyDispatcher,
        args: %{"event_id" => event.id}
      )

      refute_enqueued(worker: SmsMediaIngestor)
    end

    test "captures MediaUrl0..N into media_urls", %{conn: conn, product: product} do
      {:ok, _} =
        Sms.create_phone(%{
          product_id: product.id,
          phone_number: "+15551112222",
          role: "submitter"
        })

      params = %{
        "From" => "+15551112222",
        "To" => "+15557654321",
        "Body" => "picture for you",
        "NumMedia" => "2",
        "MediaUrl0" => "https://twilio.example/m/a.jpg",
        "MediaUrl1" => "https://twilio.example/m/b.jpg",
        "MessageSid" => "SMmedia1"
      }

      _ = post_signed(conn, params)

      [event] = Repo.all(SmsEvent)

      assert event.media_urls == [
               "https://twilio.example/m/a.jpg",
               "https://twilio.example/m/b.jpg"
             ]

      assert_enqueued(
        worker: SmsMediaIngestor,
        args: %{"event_id" => event.id}
      )
    end
  end

  describe "signed inbound from an unknown phone" do
    test "records a rejected_unknown_number event with nil product_id and returns gated TwiML",
         %{conn: conn} do
      params = %{
        "From" => "+15550000000",
        "To" => "+15557654321",
        "Body" => "hi who are you",
        "NumMedia" => "0",
        "MessageSid" => "SMunknown"
      }

      conn = post_signed(conn, params)

      assert conn.status == 200
      body = response(conn, 200)
      assert body =~ "<Message"
      assert body =~ "contact" or body =~ "not recognized" or body =~ "agency"

      assert [event] = Repo.all(SmsEvent)
      assert event.status == "rejected_unknown_number"
      assert event.direction == "inbound"
      assert event.phone_number == "+15550000000"
      assert event.product_id == nil

      assert [] = Repo.all(ConversationSession)
      refute_enqueued(worker: SmsReplyDispatcher)
    end
  end

  describe "signed inbound from a known inactive phone" do
    test "records rejected_unknown_number with product_id preserved and returns gated TwiML",
         %{conn: conn, product: product} do
      {:ok, phone} =
        Sms.create_phone(%{
          product_id: product.id,
          phone_number: "+15551112222",
          role: "owner"
        })

      {:ok, _} = Sms.deactivate_phone(phone)

      params = %{
        "From" => "+15551112222",
        "To" => "+15557654321",
        "Body" => "am I still allowed in",
        "NumMedia" => "0",
        "MessageSid" => "SMinactive"
      }

      conn = post_signed(conn, params)

      assert conn.status == 200
      assert response(conn, 200) =~ "<Message"

      assert [event] = Repo.all(SmsEvent)
      assert event.status == "rejected_unknown_number"
      assert event.product_id == product.id

      assert [] = Repo.all(ConversationSession)
      refute_enqueued(worker: SmsReplyDispatcher)
    end
  end

  describe "signature verification" do
    test "returns 403 when the signature is wrong", %{conn: conn} do
      params = %{
        "From" => "+15551112222",
        "To" => "+15557654321",
        "Body" => "hello",
        "NumMedia" => "0",
        "MessageSid" => "SMbad"
      }

      log =
        capture_log(fn ->
          result =
            post_signed(conn, params, signature: "bogus-signature-not-base64-hmac")

          send(self(), {:result, result})
        end)

      assert_received {:result, conn}
      assert conn.status == 403
      assert log =~ "rejected"
      assert [] = Repo.all(SmsEvent)
    end

    test "returns 400 when the signature header is missing", %{conn: conn} do
      params = %{
        "From" => "+15551112222",
        "To" => "+15557654321",
        "Body" => "hello",
        "NumMedia" => "0"
      }

      log =
        capture_log(fn ->
          conn =
            conn
            |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
            |> post(@webhook_path, params)

          send(self(), {:conn, conn})
        end)

      assert_received {:conn, conn}
      assert conn.status == 400
      assert log =~ "rejected"
      assert [] = Repo.all(SmsEvent)
    end

    test "rejects all requests (403) when auth_token is unset (fail closed)",
         %{conn: conn} do
      Application.put_env(:content_forge, @twilio_config_key, auth_token: nil)

      params = %{
        "From" => "+15551112222",
        "To" => "+15557654321",
        "Body" => "hi",
        "NumMedia" => "0"
      }

      log =
        capture_log(fn ->
          # Sign with an irrelevant token; plug should reject without even
          # trying to verify against a missing secret.
          result = post_signed(conn, params, signature: sign(webhook_url(conn), params, "any"))
          send(self(), {:result, result})
        end)

      assert_received {:result, conn}
      assert conn.status == 403
      assert log =~ "rejected"
      assert [] = Repo.all(SmsEvent)
    end
  end

  describe "malformed payloads" do
    test "returns 400 and records no event when From is missing",
         %{conn: conn} do
      params = %{
        "To" => "+15557654321",
        "Body" => "missing from",
        "NumMedia" => "0"
      }

      log =
        capture_log(fn ->
          result = post_signed(conn, params)
          send(self(), {:result, result})
        end)

      assert_received {:result, conn}
      assert conn.status == 400
      assert response(conn, 400) =~ "missing"
      assert log =~ "malformed"
      assert [] = Repo.all(SmsEvent)
    end
  end

  describe "STOP opt-out from a whitelisted active phone" do
    for keyword <- [
          "STOP",
          "STOPALL",
          "UNSUBSCRIBE",
          "CANCEL",
          "END",
          "QUIT",
          "stop",
          "  stopall  "
        ] do
      @opt_out_body keyword

      test "#{keyword} pauses reminders, records stop_received, and skips the auto-reply",
           %{conn: conn, product: product} do
        {:ok, phone} =
          Sms.create_phone(%{
            product_id: product.id,
            phone_number: "+15551112222",
            role: "owner"
          })

        params = %{
          "From" => "+15551112222",
          "To" => "+15557654321",
          "Body" => @opt_out_body,
          "NumMedia" => "0",
          "MessageSid" => "SMstop_#{System.unique_integer([:positive])}"
        }

        conn = post_signed(conn, params)
        assert conn.status == 200
        body = response(conn, 200)
        assert body =~ "<Message"
        assert body =~ "unsubscribed" or body =~ "STOP" or body =~ "opt"

        [event] = Sms.list_events(product.id, status: "stop_received")
        assert event.direction == "inbound"
        assert event.phone_number == "+15551112222"

        reloaded = Repo.get!(ContentForge.Sms.ProductPhone, phone.id)
        assert reloaded.reminders_paused_until != nil
        assert DateTime.compare(reloaded.reminders_paused_until, DateTime.utc_now()) == :gt

        refute_enqueued(worker: SmsReplyDispatcher)
      end
    end
  end

  describe "START resume from a whitelisted active phone" do
    for keyword <- ["START", "UNSTOP", "start", "unstop", "  Start  "] do
      @opt_in_body keyword

      test "#{keyword} clears pause, records start_received, and continues normal flow",
           %{conn: conn, product: product} do
        {:ok, phone} =
          Sms.create_phone(%{
            product_id: product.id,
            phone_number: "+15551112222",
            role: "owner"
          })

        {:ok, _} = Sms.pause_phone_reminders(phone, 7)

        params = %{
          "From" => "+15551112222",
          "To" => "+15557654321",
          "Body" => @opt_in_body,
          "NumMedia" => "0",
          "MessageSid" => "SMstart_#{System.unique_integer([:positive])}"
        }

        conn = post_signed(conn, params)
        assert conn.status == 200

        [start_event] = Sms.list_events(product.id, status: "start_received")
        assert start_event.phone_number == "+15551112222"

        reloaded = Repo.get!(ContentForge.Sms.ProductPhone, phone.id)
        assert reloaded.reminders_paused_until == nil

        # Normal auto-reply still runs after START.
        assert_enqueued(worker: SmsReplyDispatcher)
      end
    end
  end

  describe "STOP from an unknown phone" do
    test "takes the generic rejection path (no existence leak)",
         %{conn: conn} do
      params = %{
        "From" => "+15550009999",
        "To" => "+15557654321",
        "Body" => "STOP",
        "NumMedia" => "0",
        "MessageSid" => "SMstop_unknown"
      }

      conn = post_signed(conn, params)
      assert conn.status == 200
      assert response(conn, 200) =~ "<Message"

      # Unknown phones never get stop_received - only whitelisted ones do.
      stop_events = Enum.filter(Repo.all(SmsEvent), &(&1.status == "stop_received"))
      assert stop_events == []

      [event] = Repo.all(SmsEvent)
      assert event.status == "rejected_unknown_number"
      assert event.product_id == nil

      refute_enqueued(worker: SmsReplyDispatcher)
    end
  end
end
