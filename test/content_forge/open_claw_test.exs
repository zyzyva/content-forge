defmodule ContentForge.OpenClawTest do
  use ExUnit.Case, async: false

  alias ContentForge.OpenClaw

  @config_key :open_claw
  @stub_key ContentForge.OpenClaw

  setup do
    original = Application.get_env(:content_forge, @config_key, [])

    on_exit(fn ->
      Application.put_env(:content_forge, @config_key, original)
    end)

    Application.put_env(:content_forge, @config_key,
      base_url: "http://openclaw.test",
      api_key: "oc-test-key",
      default_timeout: 60_000,
      req_options: [plug: {Req.Test, @stub_key}]
    )

    :ok
  end

  defp openclaw_cfg, do: Application.get_env(:content_forge, @config_key)

  defp put_openclaw_cfg(cfg), do: Application.put_env(:content_forge, @config_key, cfg)

  defp batch_response(variants, overrides \\ %{}) do
    Map.merge(
      %{
        "variants" => variants,
        "model" => "openclaw-v1",
        "usage" => %{"total_tokens" => 1234}
      },
      overrides
    )
  end

  describe "status/0" do
    test "returns :ok when base_url and api_key are configured" do
      assert OpenClaw.status() == :ok
    end

    test "returns :not_configured when api_key is missing" do
      cfg = openclaw_cfg() |> Keyword.delete(:api_key)
      put_openclaw_cfg(cfg)
      assert OpenClaw.status() == :not_configured
    end

    test "returns :not_configured when base_url is missing" do
      cfg = openclaw_cfg() |> Keyword.delete(:base_url)
      put_openclaw_cfg(cfg)
      assert OpenClaw.status() == :not_configured
    end
  end

  describe "missing configuration" do
    test "missing api_key returns {:error, :not_configured} without HTTP" do
      cfg = openclaw_cfg() |> Keyword.put(:api_key, nil)
      put_openclaw_cfg(cfg)

      test_pid = self()

      Req.Test.stub(@stub_key, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no HTTP expected when OpenClaw is unconfigured"
      end)

      assert {:error, :not_configured} =
               OpenClaw.generate_variants(%{content_type: "post", count: 5})

      refute_received :unexpected_http
    end

    test "missing base_url returns {:error, :not_configured} without HTTP" do
      cfg = openclaw_cfg() |> Keyword.put(:base_url, nil)
      put_openclaw_cfg(cfg)

      test_pid = self()

      Req.Test.stub(@stub_key, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no HTTP expected when OpenClaw base_url is missing"
      end)

      assert {:error, :not_configured} =
               OpenClaw.generate_variants(%{content_type: "post", count: 5})

      refute_received :unexpected_http
    end
  end

  describe "happy path: social post batch" do
    test "returns a list of variants with model and usage metadata" do
      Req.Test.stub(@stub_key, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/v1/generate"

        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer oc-test-key"]

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        {:ok, decoded} = JSON.decode(body)

        assert decoded["content_type"] == "post"
        assert decoded["platform"] == "twitter"
        assert decoded["angle"] == "educational"
        assert decoded["count"] == 3
        assert decoded["brief"] =~ "voice profile"

        Req.Test.json(
          conn,
          batch_response([
            %{"text" => "variant 1", "angle" => "educational", "model" => "openclaw-v1"},
            %{"text" => "variant 2", "angle" => "humor", "model" => "openclaw-v1"},
            %{"text" => "variant 3", "angle" => "educational", "model" => "openclaw-v1"}
          ])
        )
      end)

      request = %{
        content_type: "post",
        platform: "twitter",
        angle: "educational",
        count: 3,
        brief: "Content brief text with voice profile",
        product: %{name: "Test Product", voice_profile: "professional"}
      }

      assert {:ok, %{variants: variants, model: "openclaw-v1", usage: usage}} =
               OpenClaw.generate_variants(request)

      assert length(variants) == 3
      assert Enum.all?(variants, fn v -> is_binary(v.text) end)
      assert Enum.any?(variants, fn v -> v.angle == "humor" end)
      assert usage["total_tokens"] == 1234
    end
  end

  describe "happy path: blog and video_script" do
    test "blog request carries content_type blog and no platform field" do
      Req.Test.stub(@stub_key, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        {:ok, decoded} = JSON.decode(body)

        assert decoded["content_type"] == "blog"
        refute Map.has_key?(decoded, "platform")

        Req.Test.json(
          conn,
          batch_response([
            %{"text" => "blog draft 1", "angle" => "educational", "model" => "openclaw-v1"}
          ])
        )
      end)

      assert {:ok, %{variants: [%{text: "blog draft 1"}]}} =
               OpenClaw.generate_variants(%{
                 content_type: "blog",
                 count: 1,
                 brief: "b",
                 product: %{name: "p", voice_profile: "v"}
               })
    end

    test "video_script request carries content_type video_script" do
      Req.Test.stub(@stub_key, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        {:ok, decoded} = JSON.decode(body)

        assert decoded["content_type"] == "video_script"

        Req.Test.json(
          conn,
          batch_response([
            %{"text" => "script 1", "angle" => "educational", "model" => "openclaw-v1"}
          ])
        )
      end)

      assert {:ok, _} =
               OpenClaw.generate_variants(%{
                 content_type: "video_script",
                 count: 1,
                 brief: "b",
                 product: %{name: "p", voice_profile: "v"}
               })
    end

    test "performance_insights are passed through when supplied" do
      Req.Test.stub(@stub_key, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        {:ok, decoded} = JSON.decode(body)

        assert decoded["performance_insights"] == %{"top_angle" => "humor"}

        Req.Test.json(conn, batch_response([]))
      end)

      assert {:ok, _} =
               OpenClaw.generate_variants(%{
                 content_type: "post",
                 platform: "twitter",
                 count: 1,
                 brief: "b",
                 product: %{name: "p", voice_profile: "v"},
                 performance_insights: %{"top_angle" => "humor"}
               })
    end
  end

  describe "error classification" do
    test "429 rate-limit response is transient" do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(429, JSON.encode!(%{"error" => "rate_limited"}))
      end)

      assert {:error, {:transient, 429, _}} =
               OpenClaw.generate_variants(%{content_type: "post", count: 1})
    end

    test "500 response is transient" do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, JSON.encode!(%{"error" => "internal"}))
      end)

      assert {:error, {:transient, 500, _}} =
               OpenClaw.generate_variants(%{content_type: "post", count: 1})
    end

    test "400 invalid-request response is permanent" do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, JSON.encode!(%{"error" => "invalid"}))
      end)

      assert {:error, {:http_error, 400, _}} =
               OpenClaw.generate_variants(%{content_type: "post", count: 1})
    end

    test "401 unauthorized response is permanent" do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(401, JSON.encode!(%{"error" => "unauthorized"}))
      end)

      assert {:error, {:http_error, 401, _}} =
               OpenClaw.generate_variants(%{content_type: "post", count: 1})
    end

    test "transport timeout classifies as transient :timeout" do
      Req.Test.stub(@stub_key, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, {:transient, :timeout, _}} =
               OpenClaw.generate_variants(%{content_type: "post", count: 1})
    end

    test "connection refused classifies as transient :network" do
      Req.Test.stub(@stub_key, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, {:transient, :network, :econnrefused}} =
               OpenClaw.generate_variants(%{content_type: "post", count: 1})
    end

    test "304 unexpected status reaches the classifier" do
      Req.Test.stub(@stub_key, fn conn ->
        Plug.Conn.resp(conn, 304, "")
      end)

      assert {:error, {:unexpected_status, 304, _}} =
               OpenClaw.generate_variants(%{content_type: "post", count: 1})
    end

    test "client does not retry internally on classified errors" do
      counter = :counters.new(1, [])

      Req.Test.stub(@stub_key, fn conn ->
        :counters.add(counter, 1, 1)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, JSON.encode!(%{"error" => "overloaded"}))
      end)

      assert {:error, {:transient, 503, _}} =
               OpenClaw.generate_variants(%{content_type: "post", count: 1})

      assert :counters.get(counter, 1) == 1
    end
  end
end
