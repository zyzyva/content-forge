defmodule ContentForge.Sms.EscalationTest do
  use ContentForge.DataCase, async: false
  use Oban.Testing, repo: ContentForge.Repo

  import ExUnit.CaptureLog

  alias ContentForge.Jobs.SmsReplyDispatcher
  alias ContentForge.Products
  alias ContentForge.Sms
  alias ContentForge.Sms.ConversationSession

  @twilio_key :twilio
  @twilio_stub ContentForge.Twilio

  setup do
    twilio_original = Application.get_env(:content_forge, @twilio_key, [])

    on_exit(fn ->
      Application.put_env(:content_forge, @twilio_key, twilio_original)
    end)

    Application.put_env(:content_forge, @twilio_key,
      base_url: "http://twilio.test",
      account_sid: "ACtest",
      auth_token: "twilio-auth-token",
      from_number: "+15557654321",
      default_messaging_service_sid: nil,
      req_options: [plug: {Req.Test, @twilio_stub}]
    )

    {:ok, product} =
      Products.create_product(%{name: "Escalation Product", voice_profile: "professional"})

    {:ok, _phone} =
      Sms.create_phone(%{
        product_id: product.id,
        phone_number: "+15551112222",
        role: "owner"
      })

    {:ok, session} = Sms.get_or_start_session(product.id, "+15551112222")

    %{product: product, session: session}
  end

  defp make_inbound_event!(product, body \\ "I need help") do
    {:ok, event} =
      Sms.record_event(%{
        product_id: product.id,
        phone_number: "+15551112222",
        direction: "inbound",
        status: "received",
        body: body
      })

    event
  end

  describe "escalate_session/3" do
    test "sets escalated_at, reason, and auto_response_paused", %{session: session} do
      assert {:ok, escalated} =
               Sms.escalate_session(session, "bot could not answer")

      assert %DateTime{} = escalated.escalated_at
      assert escalated.escalation_reason == "bot could not answer"
      assert escalated.auto_response_paused == true
    end

    test "records an escalated SmsEvent audit row", %{session: session, product: product} do
      {:ok, _} =
        Sms.escalate_session(session, "bot confused", notify_channels: [:dashboard])

      [event] = Sms.list_events(product.id, status: "escalated")
      assert event.body =~ "bot confused"
      assert event.body =~ "dashboard"
    end
  end

  describe "resolve_session/1" do
    test "clears escalation flags", %{session: session} do
      {:ok, escalated} = Sms.escalate_session(session, "bot stumped")
      assert escalated.auto_response_paused == true

      assert {:ok, resolved} = Sms.resolve_session(escalated)
      assert resolved.escalated_at == nil
      assert resolved.escalation_reason == nil
      assert resolved.auto_response_paused == false
    end
  end

  describe "list_escalated_sessions/0" do
    test "returns currently-escalated sessions newest-first", %{session: session, product: _p} do
      {:ok, _} = Sms.escalate_session(session, "first")

      {:ok, product2} =
        Products.create_product(%{name: "P2", voice_profile: "casual"})

      {:ok, _p2_phone} =
        Sms.create_phone(%{
          product_id: product2.id,
          phone_number: "+15553334444",
          role: "owner"
        })

      {:ok, session2} = Sms.get_or_start_session(product2.id, "+15553334444")
      Process.sleep(5)
      {:ok, _} = Sms.escalate_session(session2, "second")

      [first, second] = Sms.list_escalated_sessions()
      assert first.product_id == product2.id
      assert second.product_id == session.product_id
    end

    test "excludes resolved sessions", %{session: session} do
      {:ok, escalated} = Sms.escalate_session(session, "for a minute")
      {:ok, _} = Sms.resolve_session(escalated)

      assert Sms.list_escalated_sessions() == []
    end
  end

  describe "list_high_volume_sessions/1" do
    test "returns sessions with >= threshold inbound + no outbound in window",
         %{product: product, session: session} do
      Enum.each(1..11, fn _ -> make_inbound_event!(product) end)

      [match] = Sms.list_high_volume_sessions(threshold: 10, seconds: 86_400)
      assert match.id == session.id
    end

    test "excludes sessions that have outbound replies in window",
         %{product: product} do
      Enum.each(1..11, fn _ -> make_inbound_event!(product) end)

      {:ok, _} =
        Sms.record_event(%{
          product_id: product.id,
          phone_number: "+15551112222",
          direction: "outbound",
          status: "sent",
          body: "reply"
        })

      assert Sms.list_high_volume_sessions(threshold: 10, seconds: 86_400) == []
    end

    test "excludes already-escalated sessions",
         %{product: product, session: session} do
      Enum.each(1..11, fn _ -> make_inbound_event!(product) end)
      {:ok, _} = Sms.escalate_session(session, "already on a human's plate")

      assert Sms.list_high_volume_sessions(threshold: 10, seconds: 86_400) == []
    end

    test "honors the threshold", %{product: product} do
      Enum.each(1..5, fn _ -> make_inbound_event!(product) end)

      assert Sms.list_high_volume_sessions(threshold: 10) == []
      assert [_] = Sms.list_high_volume_sessions(threshold: 5)
    end
  end

  describe "SmsReplyDispatcher short-circuit on escalated session" do
    test "sends the holding message exactly once per escalation",
         %{product: product, session: session} do
      {:ok, _escalated} = Sms.escalate_session(session, "need a human")

      event_a = make_inbound_event!(product, "first inbound post-escalation")

      test_pid = self()

      Req.Test.stub(@twilio_stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:holding_body, raw})
        Req.Test.json(conn, %{"sid" => "SMholding1", "status" => "queued"})
      end)

      assert {:ok, :unavailable_fallback} =
               perform_job(SmsReplyDispatcher, %{"event_id" => event_a.id})

      assert_received {:holding_body, raw}
      params = URI.decode_query(raw)
      assert params["Body"] =~ "human" or params["Body"] =~ "follow up"

      # A second inbound while still escalated - no Twilio call.
      event_b = make_inbound_event!(product, "ping again")

      Req.Test.stub(@twilio_stub, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no Twilio expected for already-holding escalated session"
      end)

      capture_log(fn ->
        assert {:ok, :escalated_paused} =
                 perform_job(SmsReplyDispatcher, %{"event_id" => event_b.id})
      end)

      refute_received :unexpected_http
    end

    test "after resolve, the dispatcher resumes the normal fallback path",
         %{product: product, session: session} do
      {:ok, escalated} = Sms.escalate_session(session, "temporarily")
      {:ok, _} = Sms.resolve_session(escalated)

      event = make_inbound_event!(product, "back on track")

      Req.Test.stub(@twilio_stub, fn conn ->
        Req.Test.json(conn, %{"sid" => "SMnormal", "status" => "queued"})
      end)

      assert {:ok, :unavailable_fallback} =
               perform_job(SmsReplyDispatcher, %{"event_id" => event.id})
    end

    test "an escalated session with NO holding message yet still sends it",
         %{product: product, session: session} do
      # Manually mark escalated without the helper so we can inspect the
      # "first inbound after escalation" path cleanly.
      {:ok, _} =
        session
        |> ConversationSession.changeset(%{
          escalated_at: DateTime.utc_now(),
          escalation_reason: "manual",
          auto_response_paused: true
        })
        |> Repo.update()

      event = make_inbound_event!(product, "hello?")

      Req.Test.stub(@twilio_stub, fn conn ->
        Req.Test.json(conn, %{"sid" => "SMholding_first", "status" => "queued"})
      end)

      assert {:ok, :unavailable_fallback} =
               perform_job(SmsReplyDispatcher, %{"event_id" => event.id})

      outbound = Sms.list_events(product.id, direction: "outbound") |> List.first()
      assert outbound.body =~ "human"
    end
  end
end
