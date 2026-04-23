defmodule ContentForge.Jobs.ReminderDispatcherTest do
  use ContentForge.DataCase, async: false
  use Oban.Testing, repo: ContentForge.Repo

  import ExUnit.CaptureLog

  alias ContentForge.Jobs.ReminderDispatcher
  alias ContentForge.Products
  alias ContentForge.Sms

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
      Products.create_product(%{name: "Reminder Product", voice_profile: "professional"})

    {:ok, phone} =
      Sms.create_phone(%{
        product_id: product.id,
        phone_number: "+15551112222",
        role: "owner"
      })

    {:ok, _} =
      Sms.upsert_reminder_config(product.id, %{
        cadence_days: 3,
        backoff_after_ignored: 2,
        stop_after_ignored: 4
      })

    %{product: product, phone: phone}
  end

  defp twilio_success(sid), do: %{"sid" => sid, "status" => "queued"}

  defp seed_prior_outbound!(product, phone, count) do
    Enum.each(1..count, fn i ->
      {:ok, _} =
        Sms.record_event(%{
          product_id: product.id,
          phone_number: phone.phone_number,
          direction: "outbound",
          status: "sent",
          body: "prior reminder ##{i}"
        })
    end)
  end

  defp run(phone, product) do
    perform_job(ReminderDispatcher, %{
      "phone_id" => phone.id,
      "product_id" => product.id
    })
  end

  describe "template selection by consecutive-ignored count" do
    test "zero prior reminders -> friendly template", %{phone: phone, product: product} do
      test_pid = self()

      Req.Test.stub(@twilio_stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:raw, raw})
        Req.Test.json(conn, twilio_success("SMfriendly"))
      end)

      assert {:ok, :sent} = run(phone, product)

      assert_received {:raw, raw}
      body = URI.decode_query(raw)["Body"]
      assert body =~ "checking in" or body =~ "hi" or body =~ "hello"
      refute body =~ "stop"

      [event] = Sms.list_events(product.id, direction: "outbound")
      assert event.status == "sent"
      assert event.body =~ body || event.body == body
    end

    test "ignored count == backoff threshold -> gentler template",
         %{phone: phone, product: product} do
      # backoff_after_ignored = 2, stop_after_ignored = 4.
      # Seed 2 prior outbound with no intervening inbound -> count = 2.
      seed_prior_outbound!(product, phone, 2)

      test_pid = self()

      Req.Test.stub(@twilio_stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:raw, raw})
        Req.Test.json(conn, twilio_success("SMgentler"))
      end)

      assert {:ok, :sent} = run(phone, product)

      assert_received {:raw, raw}
      body = URI.decode_query(raw)["Body"]
      assert body =~ "circle" or body =~ "heads up" or body =~ "follow"
    end

    test "ignored count >= stop threshold -> stop-notify template + no retry",
         %{phone: phone, product: product} do
      # stop_after_ignored = 4. Seed 4 prior outbound -> count = 4.
      seed_prior_outbound!(product, phone, 4)

      test_pid = self()

      Req.Test.stub(@twilio_stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:raw, raw})
        Req.Test.json(conn, twilio_success("SMstop"))
      end)

      assert {:ok, :stop_notify} = run(phone, product)

      assert_received {:raw, raw}
      body = URI.decode_query(raw)["Body"]
      assert body =~ "last" or body =~ "final" or body =~ "won't"
    end

    test "intervening inbound resets the counter to 0",
         %{phone: phone, product: product} do
      seed_prior_outbound!(product, phone, 3)

      # An inbound lands AFTER the 3 ignored reminders -> counter resets.
      {:ok, _} =
        Sms.record_event(%{
          product_id: product.id,
          phone_number: phone.phone_number,
          direction: "inbound",
          status: "received",
          body: "sorry, just saw this"
        })

      Req.Test.stub(@twilio_stub, fn conn ->
        Req.Test.json(conn, twilio_success("SMreset"))
      end)

      assert {:ok, :sent} = run(phone, product)

      [reply | _prior] = Sms.list_events(product.id, direction: "outbound")
      refute reply.body =~ "last"
    end
  end

  describe "Twilio failure modes" do
    test "Twilio :not_configured records failed outbound + {:ok, :twilio_not_configured}",
         %{phone: phone, product: product} do
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
        raise "no HTTP expected when Twilio is not configured"
      end)

      log =
        capture_log(fn ->
          assert {:ok, :twilio_not_configured} = run(phone, product)
        end)

      refute_received :unexpected_http
      assert log =~ "Twilio unavailable"

      failed = Sms.list_events(product.id, direction: "outbound", status: "failed")
      assert length(failed) == 1
    end

    test "transient Twilio error returns {:error, _} for retry; no audit row",
         %{phone: phone, product: product} do
      Req.Test.stub(@twilio_stub, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"message" => "server error"})
      end)

      capture_log(fn ->
        assert {:error, {:transient, 500, _}} = run(phone, product)
      end)

      assert Sms.list_events(product.id, direction: "outbound") == []
    end

    test "permanent Twilio error records failed outbound + cancel",
         %{phone: phone, product: product} do
      Req.Test.stub(@twilio_stub, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"message" => "bad number"})
      end)

      capture_log(fn ->
        assert {:cancel, reason} = run(phone, product)
        assert reason =~ "HTTP 400"
      end)

      failed = Sms.list_events(product.id, direction: "outbound", status: "failed")
      assert length(failed) == 1
    end
  end

  describe "bad input" do
    test "unknown phone cancels", %{product: product} do
      capture_log(fn ->
        assert {:cancel, reason} =
                 perform_job(ReminderDispatcher, %{
                   "phone_id" => "00000000-0000-0000-0000-000000000000",
                   "product_id" => product.id
                 })

        assert reason =~ "phone"
      end)
    end

    test "paused phone is skipped without a Twilio call",
         %{phone: phone, product: product} do
      {:ok, _} = Sms.pause_phone_reminders(phone, 3)

      test_pid = self()

      Req.Test.stub(@twilio_stub, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no HTTP expected for paused phone"
      end)

      capture_log(fn ->
        assert {:ok, :paused} = run(phone, product)
      end)

      refute_received :unexpected_http
      assert Sms.list_events(product.id, direction: "outbound") == []
    end
  end
end
