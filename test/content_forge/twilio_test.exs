defmodule ContentForge.TwilioTest do
  use ExUnit.Case, async: false

  alias ContentForge.Twilio

  @config_key :twilio
  @stub_key ContentForge.Twilio

  setup do
    original = Application.get_env(:content_forge, @config_key, [])

    on_exit(fn ->
      Application.put_env(:content_forge, @config_key, original)
    end)

    Application.put_env(:content_forge, @config_key,
      base_url: "http://twilio.test",
      account_sid: "ACtest12345",
      auth_token: "twilio-auth-token",
      from_number: "+15557654321",
      default_messaging_service_sid: nil,
      req_options: [plug: {Req.Test, @stub_key}]
    )

    :ok
  end

  defp twilio_cfg, do: Application.get_env(:content_forge, @config_key)

  defp put_cfg(cfg), do: Application.put_env(:content_forge, @config_key, cfg)

  defp twilio_success(overrides \\ %{}) do
    Map.merge(
      %{
        "sid" => "SM_sid_0001",
        "status" => "queued",
        "to" => "+15551112222",
        "from" => "+15557654321",
        "body" => "hello"
      },
      overrides
    )
  end

  defp read_form_body(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {URI.decode_query(body), conn}
  end

  describe "status/0" do
    test "returns :ok when account_sid, auth_token, and from_number are configured" do
      assert Twilio.status() == :ok
    end

    test "returns :ok when messaging_service_sid is configured in place of from_number" do
      cfg =
        twilio_cfg()
        |> Keyword.put(:from_number, nil)
        |> Keyword.put(:default_messaging_service_sid, "MGxxxx1111")

      put_cfg(cfg)
      assert Twilio.status() == :ok
    end

    test "returns :not_configured when account_sid is missing" do
      put_cfg(twilio_cfg() |> Keyword.put(:account_sid, nil))
      assert Twilio.status() == :not_configured
    end

    test "returns :not_configured when auth_token is empty" do
      put_cfg(twilio_cfg() |> Keyword.put(:auth_token, ""))
      assert Twilio.status() == :not_configured
    end

    test "returns :not_configured when neither from_number nor messaging_service_sid is set" do
      cfg =
        twilio_cfg()
        |> Keyword.put(:from_number, nil)
        |> Keyword.put(:default_messaging_service_sid, nil)

      put_cfg(cfg)
      assert Twilio.status() == :not_configured
    end
  end

  describe "missing configuration" do
    test "send_sms returns {:error, :not_configured} without issuing HTTP" do
      put_cfg(twilio_cfg() |> Keyword.put(:auth_token, nil))

      test_pid = self()

      Req.Test.stub(@stub_key, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no HTTP expected when Twilio is not configured"
      end)

      assert {:error, :not_configured} = Twilio.send_sms("+15551112222", "hi")
      refute_received :unexpected_http
    end
  end

  describe "send_sms/3 happy path" do
    test "posts to the Messages endpoint with HTTP Basic auth and form-urlencoded body" do
      Req.Test.stub(@stub_key, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/2010-04-01/Accounts/ACtest12345/Messages.json"

        assert ["Basic " <> encoded] = Plug.Conn.get_req_header(conn, "authorization")
        decoded = Base.decode64!(encoded)
        assert decoded == "ACtest12345:twilio-auth-token"

        assert ["application/x-www-form-urlencoded" <> _] =
                 Plug.Conn.get_req_header(conn, "content-type")

        {params, conn} = read_form_body(conn)
        assert params["To"] == "+15551112222"
        assert params["Body"] == "hello there"
        assert params["From"] == "+15557654321"
        refute Map.has_key?(params, "MediaUrl")

        Req.Test.json(conn, twilio_success(%{"body" => "hello there"}))
      end)

      assert {:ok, %{sid: "SM_sid_0001", status: "queued"}} =
               Twilio.send_sms("+15551112222", "hello there")
    end

    test "attaches MediaUrl parameters when :media_urls is provided" do
      test_pid = self()

      Req.Test.stub(@stub_key, fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:raw_body, raw_body})
        Req.Test.json(conn, twilio_success())
      end)

      assert {:ok, _} =
               Twilio.send_sms("+15551112222", "here are pics",
                 media_urls: [
                   "https://cdn/a.jpg",
                   "https://cdn/b.jpg"
                 ]
               )

      assert_received {:raw_body, raw}
      # URI.decode_query collapses duplicate keys; inspect the raw form body
      # to prove both MediaUrl entries are present.
      assert raw =~ "MediaUrl=https%3A%2F%2Fcdn%2Fa.jpg"
      assert raw =~ "MediaUrl=https%3A%2F%2Fcdn%2Fb.jpg"
    end

    test "prefers messaging_service_sid over from_number when both are set" do
      cfg =
        twilio_cfg()
        |> Keyword.put(:default_messaging_service_sid, "MGabc123")

      put_cfg(cfg)

      Req.Test.stub(@stub_key, fn conn ->
        {params, conn} = read_form_body(conn)
        assert params["MessagingServiceSid"] == "MGabc123"
        refute Map.has_key?(params, "From")
        Req.Test.json(conn, twilio_success())
      end)

      assert {:ok, _} = Twilio.send_sms("+15551112222", "hi")
    end

    test "accepts an explicit :from override" do
      Req.Test.stub(@stub_key, fn conn ->
        {params, conn} = read_form_body(conn)
        assert params["From"] == "+15550001111"
        Req.Test.json(conn, twilio_success())
      end)

      assert {:ok, _} = Twilio.send_sms("+15551112222", "hi", from: "+15550001111")
    end
  end

  describe "error classification" do
    test "500 -> {:transient, 500, _}" do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"code" => 50_000, "message" => "server error"})
      end)

      assert {:error, {:transient, 500, _body}} = Twilio.send_sms("+15551112222", "hi")
    end

    test "429 -> {:transient, 429, _}" do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"code" => 20_429, "message" => "too many requests"})
      end)

      assert {:error, {:transient, 429, _body}} = Twilio.send_sms("+15551112222", "hi")
    end

    test "400 -> {:http_error, 400, _}" do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"code" => 21_211, "message" => "invalid 'To' phone"})
      end)

      assert {:error, {:http_error, 400, _body}} = Twilio.send_sms("+15551112222", "hi")
    end

    test "timeout -> {:transient, :timeout, _}" do
      Req.Test.stub(@stub_key, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, {:transient, :timeout, _}} = Twilio.send_sms("+15551112222", "hi")
    end

    test "econnrefused -> {:transient, :network, _}" do
      Req.Test.stub(@stub_key, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, {:transient, :network, :econnrefused}} =
               Twilio.send_sms("+15551112222", "hi")
    end

    test "redirect 3xx -> {:unexpected_status, status, _}" do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "/elsewhere")
        |> Plug.Conn.put_status(301)
        |> Req.Test.text("moved")
      end)

      assert {:error, {:unexpected_status, 301, _body}} =
               Twilio.send_sms("+15551112222", "hi")
    end
  end
end
