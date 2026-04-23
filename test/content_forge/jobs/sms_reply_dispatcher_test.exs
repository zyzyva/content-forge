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

  describe "OpenClaw agent-turn (14.2c)" do
    setup do
      original = Application.get_env(:content_forge, :open_claw_agent, [])

      on_exit(fn ->
        Application.put_env(:content_forge, :open_claw_agent, original)
      end)

      :ok
    end

    test "when AgentGateway returns text, Twilio sends that text instead of the fallback",
         %{product: product, inbound_event: inbound_event} do
      stub_agent_shell(fn _binary, _args ->
        {~s|{"payloads":[{"text":"Hi there, how can I help?"}],"model":"claude-stub"}|, "", 0}
      end)

      Req.Test.stub(@twilio_stub, fn conn ->
        Req.Test.json(conn, twilio_sms_response("SMagent1", "queued"))
      end)

      assert {:ok, :unavailable_fallback} = run_dispatch(inbound_event.id)

      outbound = Sms.list_events(product.id, direction: "outbound") |> List.first()
      assert outbound.body == "Hi there, how can I help?"
      assert outbound.status == "sent"
    end

    test "missing agent config falls through to the fallback path without shelling out",
         %{product: product, inbound_event: inbound_event} do
      shell_pid = self()

      # Binary path points to a file that does not exist; the
      # gateway short-circuits with :not_configured and the
      # shell_impl never fires.
      Application.put_env(:content_forge, :open_claw_agent,
        binary_path: "/nonexistent/path",
        default_agent_id: "agent-test",
        shell_impl: fn _binary, _args ->
          send(shell_pid, :unexpected_shell)
          {"", "", 0}
        end
      )

      Req.Test.stub(@twilio_stub, fn conn ->
        Req.Test.json(conn, twilio_sms_response("SMfallback_oc_off", "queued"))
      end)

      assert {:ok, :unavailable_fallback} = run_dispatch(inbound_event.id)
      refute_received :unexpected_shell

      outbound = Sms.list_events(product.id, direction: "outbound") |> List.first()
      assert outbound.body == @default_fallback
    end

    test "malformed JSON from the agent falls back (permanent error, no Oban retry)",
         %{product: product, inbound_event: inbound_event} do
      stub_agent_shell(fn _binary, _args -> {"not json at all", "", 0} end)

      Req.Test.stub(@twilio_stub, fn conn ->
        Req.Test.json(conn, twilio_sms_response("SMfallback_malformed", "queued"))
      end)

      assert {:ok, :unavailable_fallback} =
               capture_log(fn -> run_dispatch(inbound_event.id) end)
               |> then(fn _ -> run_dispatch(inbound_event.id) end)

      outbound = Sms.list_events(product.id, direction: "outbound") |> List.first()
      assert outbound.body == @default_fallback
    end

    test "non-zero exit code from the agent returns a transient error for retry with stderr",
         %{inbound_event: inbound_event} do
      stub_agent_shell(fn _binary, _args ->
        {"partial stdout", "boom: binary died\n", 1}
      end)

      # Shouldn't hit Twilio since the transient error propagates
      # before we get that far.
      Req.Test.stub(@twilio_stub, fn _conn ->
        raise "Twilio should not be called on transient agent error"
      end)

      assert {:error, {:transient, :exit_code, %{code: 1, stderr: stderr}}} =
               capture_log(fn -> run_dispatch(inbound_event.id) end)
               |> then(fn _ -> run_dispatch(inbound_event.id) end)

      assert stderr =~ "boom"
    end

    test "passes session_id that threads product + phone across messages",
         %{inbound_event: inbound_event} do
      test_pid = self()

      stub_agent_shell(fn _binary, args ->
        send(test_pid, {:shell_args, args})
        {~s|{"payloads":[{"text":"ok"}]}|, "", 0}
      end)

      Req.Test.stub(@twilio_stub, fn conn ->
        Req.Test.json(conn, twilio_sms_response("SMagent_session", "queued"))
      end)

      run_dispatch(inbound_event.id)

      assert_received {:shell_args, args}
      # The session id should include both product id and phone.
      session_idx = Enum.find_index(args, &(&1 == "--session-id"))
      session_val = Enum.at(args, session_idx + 1)
      assert session_val =~ inbound_event.product_id
      assert session_val =~ inbound_event.phone_number
    end

    # Configures the OpenClaw AgentGateway with a real-on-disk
    # binary path (/bin/sh) so File.exists?/1 passes, but swaps
    # the actual shell-out with `fun` via the :shell_impl seam.
    # The stub is a 2-arity function `(binary, args)` returning
    # `{stdout, stderr, exit_code}`.
    defp stub_agent_shell(fun) do
      Application.put_env(:content_forge, :open_claw_agent,
        binary_path: "/bin/sh",
        default_agent_id: "agent-test",
        default_timeout_seconds: 5,
        shell_impl: fun
      )
    end
  end

  describe "OpenClaw agent-turn hardening (14.2c-H)" do
    setup do
      original = Application.get_env(:content_forge, :open_claw_agent, [])

      on_exit(fn ->
        Application.put_env(:content_forge, :open_claw_agent, original)
      end)

      :ok
    end

    test "timeout wrapper kills the hung subprocess and returns a transient tuple",
         %{inbound_event: inbound_event} do
      Application.put_env(:content_forge, :open_claw_agent,
        binary_path: "/bin/sh",
        default_agent_id: "agent-test",
        # 1-second budget; the stub hangs past it.
        default_timeout_seconds: 1,
        shell_impl: fn _binary, _args ->
          # Simulate a hung subprocess that the Task.async wrapper
          # must brutal-kill on expiry.
          Process.sleep(5_000)
          {"never reached", "", 0}
        end
      )

      Req.Test.stub(@twilio_stub, fn _conn ->
        raise "Twilio should not be called on agent timeout"
      end)

      assert {:error, {:transient, :timeout, 1}} =
               capture_log(fn -> run_dispatch(inbound_event.id) end)
               |> then(fn _ -> run_dispatch(inbound_event.id) end)
    end

    test "stderr and stdout are split: chatty stderr does not corrupt JSON parse",
         %{product: product, inbound_event: inbound_event} do
      Application.put_env(:content_forge, :open_claw_agent,
        binary_path: "/bin/sh",
        default_agent_id: "agent-test",
        default_timeout_seconds: 5,
        shell_impl: fn _binary, _args ->
          {~s|{"payloads":[{"text":"Hello from agent"}],"model":"claude-stub"}|,
           "WARN: deprecation notice on stderr\nINFO: noisy stderr line 2\n", 0}
        end
      )

      Req.Test.stub(@twilio_stub, fn conn ->
        Req.Test.json(conn, twilio_sms_response("SMsplit", "queued"))
      end)

      assert {:ok, :unavailable_fallback} =
               capture_log(fn -> run_dispatch(inbound_event.id) end)
               |> then(fn _ -> run_dispatch(inbound_event.id) end)

      outbound = Sms.list_events(product.id, direction: "outbound") |> List.first()
      assert outbound.body == "Hello from agent"
    end

    test "non-zero exit bubbles stderr into the error reason for operator diagnosis",
         %{inbound_event: inbound_event} do
      stderr_text = "FATAL: agent config parse error at line 42\n"

      Application.put_env(:content_forge, :open_claw_agent,
        binary_path: "/bin/sh",
        default_agent_id: "agent-test",
        default_timeout_seconds: 5,
        shell_impl: fn _binary, _args ->
          {"partial stdout", stderr_text, 2}
        end
      )

      Req.Test.stub(@twilio_stub, fn _conn ->
        raise "Twilio should not be called on transient agent error"
      end)

      assert {:error, {:transient, :exit_code, %{code: 2, stderr: stderr}}} =
               capture_log(fn -> run_dispatch(inbound_event.id) end)
               |> then(fn _ -> run_dispatch(inbound_event.id) end)

      assert stderr =~ "FATAL"
      assert stderr =~ "line 42"
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
