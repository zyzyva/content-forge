defmodule ContentForge.Jobs.SmsReplyDispatcherTest do
  use ContentForge.DataCase, async: false
  use Oban.Testing, repo: ContentForge.Repo

  import ExUnit.CaptureLog

  alias ContentForge.Jobs.SmsReplyDispatcher
  alias ContentForge.Products
  alias ContentForge.Sms

  @twilio_key :twilio
  @twilio_stub ContentForge.Twilio
  @open_claw_key :open_claw

  @default_fallback "Thanks — your assistant is temporarily unavailable. We will get back to you shortly."

  setup do
    twilio_original = Application.get_env(:content_forge, @twilio_key, [])
    open_claw_original = Application.get_env(:content_forge, @open_claw_key, [])
    sms_original = Application.get_env(:content_forge, :sms, [])

    on_exit(fn ->
      Application.put_env(:content_forge, @twilio_key, twilio_original)
      Application.put_env(:content_forge, @open_claw_key, open_claw_original)
      Application.put_env(:content_forge, :sms, sms_original)
    end)

    Application.put_env(:content_forge, @twilio_key,
      base_url: "http://twilio.test",
      account_sid: "ACtest",
      auth_token: "twilio-auth-token",
      from_number: "+15557654321",
      default_messaging_service_sid: nil,
      req_options: [plug: {Req.Test, @twilio_stub}]
    )

    # OpenClaw OFF by default for these tests.
    Application.put_env(:content_forge, @open_claw_key,
      base_url: nil,
      api_key: nil
    )

    Application.put_env(:content_forge, :sms, outbound_rate_limit_per_day: 10)

    {:ok, product} =
      Products.create_product(%{name: "SMS Reply Product", voice_profile: "professional"})

    {:ok, _phone} =
      Sms.create_phone(%{
        product_id: product.id,
        phone_number: "+15551112222",
        role: "owner"
      })

    {:ok, inbound_event} =
      Sms.record_event(%{
        product_id: product.id,
        phone_number: "+15551112222",
        direction: "inbound",
        status: "received",
        body: "hello agent",
        twilio_sid: "SMinbound"
      })

    {:ok, _session} = Sms.get_or_start_session(product.id, "+15551112222")

    %{product: product, inbound_event: inbound_event}
  end

  defp twilio_sms_response(sid, status) do
    %{"sid" => sid, "status" => status, "to" => "+15551112222", "from" => "+15557654321"}
  end

  defp run_dispatch(event_id) do
    perform_job(SmsReplyDispatcher, %{"event_id" => event_id})
  end

  describe "happy path: OpenClaw off -> send unavailable fallback" do
    test "sends the default fallback via Twilio and records outbound sent event",
         %{product: product, inbound_event: inbound_event} do
      test_pid = self()

      Req.Test.stub(@twilio_stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:twilio_body, raw})
        Req.Test.json(conn, twilio_sms_response("SMfallback1", "queued"))
      end)

      assert {:ok, :unavailable_fallback} = run_dispatch(inbound_event.id)

      assert_received {:twilio_body, raw}
      assert raw =~ URI.encode_www_form(@default_fallback)
      assert raw =~ "To=%2B15551112222"

      outbound =
        Sms.list_events(product.id, direction: "outbound") |> List.first()

      assert outbound.status == "sent"
      assert outbound.phone_number == "+15551112222"
      assert outbound.body == @default_fallback
      assert outbound.twilio_sid == "SMfallback1"
    end

    test "uses a per-product fallback override when configured",
         %{product: product, inbound_event: inbound_event} do
      {:ok, product} =
        Products.update_product(product, %{
          publishing_targets: %{
            "sms" => %{"unavailable_fallback" => "Hang tight, Johnson!"}
          }
        })

      test_pid = self()

      Req.Test.stub(@twilio_stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:raw, raw})
        Req.Test.json(conn, twilio_sms_response("SMfallback_custom", "queued"))
      end)

      assert {:ok, :unavailable_fallback} = run_dispatch(inbound_event.id)

      assert_received {:raw, raw}
      assert raw =~ URI.encode_www_form("Hang tight, Johnson!")

      outbound =
        Sms.list_events(product.id, direction: "outbound") |> List.first()

      assert outbound.body == "Hang tight, Johnson!"
    end
  end

  describe "OpenClaw configured: still ships fallback this slice" do
    test "OpenClaw on still sends fallback (14.2c will replace this branch)",
         %{product: product, inbound_event: inbound_event} do
      Application.put_env(:content_forge, @open_claw_key,
        base_url: "http://openclaw.test",
        api_key: "oc-test-key"
      )

      Req.Test.stub(@twilio_stub, fn conn ->
        Req.Test.json(conn, twilio_sms_response("SMfallback_oc", "queued"))
      end)

      assert {:ok, :unavailable_fallback} = run_dispatch(inbound_event.id)

      outbound = Sms.list_events(product.id, direction: "outbound") |> List.first()
      assert outbound.body == @default_fallback
      assert outbound.status == "sent"
    end
  end

  describe "rate limiting" do
    test "the 11th outbound within 24h is rejected without a Twilio call",
         %{product: product, inbound_event: inbound_event} do
      Enum.each(1..10, fn i ->
        {:ok, _} =
          Sms.record_event(%{
            product_id: product.id,
            phone_number: "+15551112222",
            direction: "outbound",
            status: "sent",
            body: "auto reply ##{i}",
            twilio_sid: "SMhist#{i}"
          })
      end)

      test_pid = self()

      Req.Test.stub(@twilio_stub, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no Twilio HTTP expected when rate-limited"
      end)

      log =
        capture_log(fn ->
          assert {:ok, :rate_limited} = run_dispatch(inbound_event.id)
        end)

      refute_received :unexpected_http

      assert log =~ "rate-limit"

      rejected =
        Sms.list_events(product.id,
          direction: "outbound",
          status: "rejected_rate_limit"
        )

      assert length(rejected) == 1
      assert hd(rejected).phone_number == "+15551112222"
    end

    test "under the limit the call proceeds as normal",
         %{product: _product, inbound_event: inbound_event} do
      Enum.each(1..5, fn i ->
        {:ok, _} =
          Sms.record_event(%{
            product_id: inbound_event.product_id,
            phone_number: "+15551112222",
            direction: "outbound",
            status: "sent",
            body: "auto reply ##{i}",
            twilio_sid: "SMhistok#{i}"
          })
      end)

      Req.Test.stub(@twilio_stub, fn conn ->
        Req.Test.json(conn, twilio_sms_response("SMrate_under", "queued"))
      end)

      assert {:ok, :unavailable_fallback} = run_dispatch(inbound_event.id)
    end
  end

  describe "Twilio failure modes" do
    test "Twilio :not_configured records a failed outbound event and does not crash",
         %{product: product, inbound_event: inbound_event} do
      Application.put_env(:content_forge, @twilio_key,
        base_url: "http://twilio.test",
        account_sid: nil,
        auth_token: nil,
        from_number: nil,
        default_messaging_service_sid: nil,
        req_options: [plug: {Req.Test, @twilio_stub}]
      )

      test_pid = self()

      Req.Test.stub(@twilio_stub, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no Twilio HTTP expected when client is not configured"
      end)

      log =
        capture_log(fn ->
          assert {:ok, :twilio_not_configured} = run_dispatch(inbound_event.id)
        end)

      refute_received :unexpected_http
      assert log =~ "Twilio unavailable"

      failed =
        Sms.list_events(product.id, direction: "outbound", status: "failed")

      assert length(failed) == 1
      assert hd(failed).body == @default_fallback
    end

    test "transient Twilio error returns {:error, _} for Oban retry; no outbound event",
         %{product: product, inbound_event: inbound_event} do
      Req.Test.stub(@twilio_stub, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"message" => "server error"})
      end)

      log =
        capture_log(fn ->
          assert {:error, {:transient, 500, _}} = run_dispatch(inbound_event.id)
        end)

      assert log =~ "transient"
      assert Sms.list_events(product.id, direction: "outbound") == []
    end

    test "permanent Twilio error records failed outbound + cancel",
         %{product: product, inbound_event: inbound_event} do
      Req.Test.stub(@twilio_stub, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"message" => "invalid To"})
      end)

      log =
        capture_log(fn ->
          assert {:cancel, reason} = run_dispatch(inbound_event.id)
          assert reason =~ "HTTP 400"
        end)

      assert log =~ "permanent"

      failed = Sms.list_events(product.id, direction: "outbound", status: "failed")
      assert length(failed) == 1
    end
  end

  describe "bad input" do
    test "unknown event_id cancels without side effects", %{product: product} do
      log =
        capture_log(fn ->
          assert {:cancel, reason} =
                   run_dispatch("00000000-0000-0000-0000-000000000000")

          assert reason =~ "event"
        end)

      assert log =~ "SmsReplyDispatcher"
      assert Sms.list_events(product.id, direction: "outbound") == []
    end

    test "outbound events are skipped (dispatcher only replies to inbound)",
         %{product: product} do
      {:ok, outbound_event} =
        Sms.record_event(%{
          product_id: product.id,
          phone_number: "+15551112222",
          direction: "outbound",
          status: "sent",
          body: "outbound noise"
        })

      test_pid = self()

      Req.Test.stub(@twilio_stub, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no Twilio HTTP expected for outbound event"
      end)

      log =
        capture_log(fn ->
          assert {:cancel, reason} = run_dispatch(outbound_event.id)
          assert reason =~ "inbound"
        end)

      refute_received :unexpected_http
      assert log =~ "SmsReplyDispatcher"
    end

    test "inbound event without product_id (unknown sender) is skipped" do
      {:ok, orphan_event} =
        Sms.record_event(%{
          phone_number: "+15550000000",
          direction: "inbound",
          status: "rejected_unknown_number"
        })

      test_pid = self()

      Req.Test.stub(@twilio_stub, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no Twilio HTTP expected for orphan event"
      end)

      capture_log(fn ->
        assert {:cancel, reason} = run_dispatch(orphan_event.id)
        assert reason =~ "product" or reason =~ "event"
      end)

      refute_received :unexpected_http
    end
  end
end
