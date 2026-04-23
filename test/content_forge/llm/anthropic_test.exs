defmodule ContentForge.LLM.AnthropicTest do
  use ExUnit.Case, async: false

  alias ContentForge.LLM.Anthropic

  @config_key :llm
  @stub_key ContentForge.LLM.Anthropic

  setup do
    original = Application.get_env(:content_forge, @config_key, [])

    on_exit(fn ->
      Application.put_env(:content_forge, @config_key, original)
    end)

    Application.put_env(:content_forge, @config_key,
      anthropic: [
        base_url: "http://anthropic.test",
        api_key: "sk-test-key",
        default_model: "claude-sonnet-4-6",
        max_tokens: 1024,
        req_options: [plug: {Req.Test, @stub_key}]
      ]
    )

    :ok
  end

  defp anthropic_cfg, do: Application.get_env(:content_forge, @config_key)[:anthropic]

  defp put_anthropic_cfg(cfg),
    do: Application.put_env(:content_forge, @config_key, anthropic: cfg)

  defp assistant_response(text, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "msg_01",
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => text}],
        "model" => "claude-sonnet-4-6",
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 12, "output_tokens" => 34}
      },
      overrides
    )
  end

  describe "status/0" do
    test "returns :ok when api_key is configured" do
      assert Anthropic.status() == :ok
    end

    test "returns :not_configured when api_key is missing" do
      cfg = anthropic_cfg() |> Keyword.delete(:api_key)
      put_anthropic_cfg(cfg)
      assert Anthropic.status() == :not_configured
    end

    test "returns :not_configured when api_key is an empty string" do
      cfg = anthropic_cfg() |> Keyword.put(:api_key, "")
      put_anthropic_cfg(cfg)
      assert Anthropic.status() == :not_configured
    end
  end

  describe "missing API key" do
    test "every call returns {:error, :not_configured} without issuing HTTP" do
      cfg = anthropic_cfg() |> Keyword.put(:api_key, nil)
      put_anthropic_cfg(cfg)

      test_pid = self()

      Req.Test.stub(@stub_key, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no HTTP expected when Anthropic is not configured"
      end)

      assert {:error, :not_configured} = Anthropic.complete("Hello?")
      refute_received :unexpected_http
    end
  end

  describe "happy path" do
    test "completion returns text plus metadata" do
      Req.Test.stub(@stub_key, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/messages"

        assert Plug.Conn.get_req_header(conn, "x-api-key") == ["sk-test-key"]
        assert [version] = Plug.Conn.get_req_header(conn, "anthropic-version")
        assert version != ""

        Req.Test.json(conn, assistant_response("Hello back!"))
      end)

      assert {:ok, %{text: "Hello back!", model: model, stop_reason: stop, usage: usage}} =
               Anthropic.complete("Hello?")

      assert model == "claude-sonnet-4-6"
      assert stop == "end_turn"
      assert usage == %{"input_tokens" => 12, "output_tokens" => 34}
    end

    test "request body honors caller overrides for model, temperature, and system" do
      Req.Test.stub(@stub_key, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        {:ok, decoded} = JSON.decode(body)

        assert decoded["model"] == "claude-opus-4-7"
        assert decoded["max_tokens"] == 2048
        assert decoded["temperature"] == 0.3
        assert decoded["system"] == "you are a terse assistant"

        assert decoded["messages"] == [
                 %{"role" => "user", "content" => "Summarize X"}
               ]

        Req.Test.json(conn, assistant_response("ok", %{"model" => "claude-opus-4-7"}))
      end)

      assert {:ok, %{text: "ok", model: "claude-opus-4-7"}} =
               Anthropic.complete("Summarize X",
                 model: "claude-opus-4-7",
                 max_tokens: 2048,
                 temperature: 0.3,
                 system: "you are a terse assistant"
               )
    end

    test "accepts a list of message turns directly" do
      Req.Test.stub(@stub_key, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        {:ok, decoded} = JSON.decode(body)

        assert decoded["messages"] == [
                 %{"role" => "user", "content" => "Hi"},
                 %{"role" => "assistant", "content" => "Hello"},
                 %{"role" => "user", "content" => "Continue"}
               ]

        Req.Test.json(conn, assistant_response("ok"))
      end)

      assert {:ok, _} =
               Anthropic.complete([
                 %{role: "user", content: "Hi"},
                 %{role: "assistant", content: "Hello"},
                 %{role: "user", content: "Continue"}
               ])
    end

    test "extracts text from the first text block when content has multiple blocks" do
      Req.Test.stub(@stub_key, fn conn ->
        body =
          assistant_response("primary text", %{
            "content" => [
              %{"type" => "text", "text" => "primary text"},
              %{"type" => "tool_use", "id" => "tool_1", "name" => "calc"}
            ]
          })

        Req.Test.json(conn, body)
      end)

      assert {:ok, %{text: "primary text"}} = Anthropic.complete("anything")
    end
  end

  describe "error classification" do
    test "429 rate-limit response is transient (Oban owns the retry)" do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "5")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(429, JSON.encode!(%{"error" => %{"type" => "rate_limit_error"}}))
      end)

      assert {:error, {:transient, 429, body}} = Anthropic.complete("anything")
      assert is_map(body) or is_binary(body)
    end

    test "500 response is transient" do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, JSON.encode!(%{"error" => "overloaded"}))
      end)

      assert {:error, {:transient, 500, _body}} = Anthropic.complete("anything")
    end

    test "400 invalid-request response is permanent" do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, JSON.encode!(%{"error" => %{"type" => "invalid_request_error"}}))
      end)

      assert {:error, {:http_error, 400, body}} = Anthropic.complete("anything")
      assert is_map(body)
    end

    test "401 unauthorized response is permanent" do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(401, JSON.encode!(%{"error" => %{"type" => "authentication_error"}}))
      end)

      assert {:error, {:http_error, 401, _body}} = Anthropic.complete("anything")
    end

    test "transport timeout classifies as transient :timeout" do
      Req.Test.stub(@stub_key, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, {:transient, :timeout, _reason}} = Anthropic.complete("anything")
    end

    test "connection refused classifies as transient :network" do
      Req.Test.stub(@stub_key, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, {:transient, :network, :econnrefused}} = Anthropic.complete("anything")
    end

    test "304 unexpected status reaches the classifier" do
      Req.Test.stub(@stub_key, fn conn ->
        Plug.Conn.resp(conn, 304, "")
      end)

      assert {:error, {:unexpected_status, 304, _body}} = Anthropic.complete("anything")
    end

    test "client does not retry internally on any classified error" do
      counter = :counters.new(1, [])

      Req.Test.stub(@stub_key, fn conn ->
        :counters.add(counter, 1, 1)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, JSON.encode!(%{"error" => "overloaded"}))
      end)

      assert {:error, {:transient, 503, _}} = Anthropic.complete("anything")
      assert :counters.get(counter, 1) == 1
    end
  end
end
