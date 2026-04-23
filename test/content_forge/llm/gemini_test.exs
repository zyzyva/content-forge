defmodule ContentForge.LLM.GeminiTest do
  use ExUnit.Case, async: false

  alias ContentForge.LLM.Gemini

  @config_key :llm
  @stub_key ContentForge.LLM.Gemini

  setup do
    original = Application.get_env(:content_forge, @config_key, [])

    on_exit(fn ->
      Application.put_env(:content_forge, @config_key, original)
    end)

    gemini =
      [
        base_url: "http://gemini.test",
        api_key: "gk-test-key",
        default_model: "gemini-2.5-flash",
        max_tokens: 1024,
        req_options: [plug: {Req.Test, @stub_key}]
      ]

    # Preserve any other providers (e.g. :anthropic) that other tests rely on
    config = Keyword.put(original, :gemini, gemini)
    Application.put_env(:content_forge, @config_key, config)

    :ok
  end

  defp gemini_cfg, do: Application.get_env(:content_forge, @config_key)[:gemini]

  defp put_gemini_cfg(cfg) do
    existing = Application.get_env(:content_forge, @config_key, [])
    Application.put_env(:content_forge, @config_key, Keyword.put(existing, :gemini, cfg))
  end

  defp candidate_response(text, overrides \\ %{}) do
    Map.merge(
      %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [%{"text" => text}],
              "role" => "model"
            },
            "finishReason" => "STOP",
            "index" => 0
          }
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 12,
          "candidatesTokenCount" => 34,
          "totalTokenCount" => 46
        },
        "modelVersion" => "gemini-2.5-flash"
      },
      overrides
    )
  end

  describe "status/0" do
    test "returns :ok when api_key is configured" do
      assert Gemini.status() == :ok
    end

    test "returns :not_configured when api_key is missing" do
      cfg = gemini_cfg() |> Keyword.delete(:api_key)
      put_gemini_cfg(cfg)
      assert Gemini.status() == :not_configured
    end

    test "returns :not_configured when api_key is an empty string" do
      cfg = gemini_cfg() |> Keyword.put(:api_key, "")
      put_gemini_cfg(cfg)
      assert Gemini.status() == :not_configured
    end
  end

  describe "missing API key" do
    test "every call returns {:error, :not_configured} without issuing HTTP" do
      cfg = gemini_cfg() |> Keyword.put(:api_key, nil)
      put_gemini_cfg(cfg)

      test_pid = self()

      Req.Test.stub(@stub_key, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no HTTP expected when Gemini is not configured"
      end)

      assert {:error, :not_configured} = Gemini.complete("Hello?")
      refute_received :unexpected_http
    end
  end

  describe "happy path" do
    test "completion returns text plus metadata" do
      Req.Test.stub(@stub_key, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1beta/models/gemini-2.5-flash:generateContent"

        assert Plug.Conn.get_req_header(conn, "x-goog-api-key") == ["gk-test-key"]

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        {:ok, decoded} = JSON.decode(body)

        assert decoded["contents"] == [
                 %{"role" => "user", "parts" => [%{"text" => "Hello?"}]}
               ]

        Req.Test.json(conn, candidate_response("Hello back!"))
      end)

      assert {:ok, %{text: "Hello back!", model: model, stop_reason: stop, usage: usage}} =
               Gemini.complete("Hello?")

      assert model == "gemini-2.5-flash"
      assert stop == "STOP"
      assert usage["totalTokenCount"] == 46
    end

    test "request body honors caller overrides for model, temperature, and system" do
      Req.Test.stub(@stub_key, fn conn ->
        assert conn.request_path == "/v1beta/models/gemini-2.5-pro:generateContent"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        {:ok, decoded} = JSON.decode(body)

        assert decoded["generationConfig"]["temperature"] == 0.3
        assert decoded["generationConfig"]["maxOutputTokens"] == 2048

        assert decoded["systemInstruction"] == %{
                 "parts" => [%{"text" => "you are a terse assistant"}]
               }

        Req.Test.json(conn, candidate_response("ok", %{"modelVersion" => "gemini-2.5-pro"}))
      end)

      assert {:ok, %{text: "ok", model: "gemini-2.5-pro"}} =
               Gemini.complete("Summarize X",
                 model: "gemini-2.5-pro",
                 max_tokens: 2048,
                 temperature: 0.3,
                 system: "you are a terse assistant"
               )
    end

    test "maps :assistant role to :model in Gemini's contents schema" do
      Req.Test.stub(@stub_key, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        {:ok, decoded} = JSON.decode(body)

        assert decoded["contents"] == [
                 %{"role" => "user", "parts" => [%{"text" => "Hi"}]},
                 %{"role" => "model", "parts" => [%{"text" => "Hello"}]},
                 %{"role" => "user", "parts" => [%{"text" => "Continue"}]}
               ]

        Req.Test.json(conn, candidate_response("ok"))
      end)

      assert {:ok, _} =
               Gemini.complete([
                 %{role: "user", content: "Hi"},
                 %{role: "assistant", content: "Hello"},
                 %{role: "user", content: "Continue"}
               ])
    end

    test "extracts text from the first text part when content has multiple parts" do
      Req.Test.stub(@stub_key, fn conn ->
        body =
          candidate_response("primary text", %{
            "candidates" => [
              %{
                "content" => %{
                  "parts" => [
                    %{"text" => "primary text"},
                    %{"functionCall" => %{"name" => "calc"}}
                  ],
                  "role" => "model"
                },
                "finishReason" => "STOP"
              }
            ]
          })

        Req.Test.json(conn, body)
      end)

      assert {:ok, %{text: "primary text"}} = Gemini.complete("anything")
    end
  end

  describe "error classification" do
    test "429 rate-limit response is transient" do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          429,
          JSON.encode!(%{"error" => %{"code" => 429, "status" => "RESOURCE_EXHAUSTED"}})
        )
      end)

      assert {:error, {:transient, 429, _body}} = Gemini.complete("anything")
    end

    test "500 response is transient" do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, JSON.encode!(%{"error" => "internal"}))
      end)

      assert {:error, {:transient, 500, _body}} = Gemini.complete("anything")
    end

    test "400 invalid-request response is permanent" do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, JSON.encode!(%{"error" => %{"status" => "INVALID_ARGUMENT"}}))
      end)

      assert {:error, {:http_error, 400, body}} = Gemini.complete("anything")
      assert is_map(body)
    end

    test "403 permission-denied response is permanent" do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(403, JSON.encode!(%{"error" => %{"status" => "PERMISSION_DENIED"}}))
      end)

      assert {:error, {:http_error, 403, _body}} = Gemini.complete("anything")
    end

    test "transport timeout classifies as transient :timeout" do
      Req.Test.stub(@stub_key, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, {:transient, :timeout, _reason}} = Gemini.complete("anything")
    end

    test "connection refused classifies as transient :network" do
      Req.Test.stub(@stub_key, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, {:transient, :network, :econnrefused}} = Gemini.complete("anything")
    end

    test "304 unexpected status reaches the classifier" do
      Req.Test.stub(@stub_key, fn conn ->
        Plug.Conn.resp(conn, 304, "")
      end)

      assert {:error, {:unexpected_status, 304, _body}} = Gemini.complete("anything")
    end

    test "client does not retry internally on any classified error" do
      counter = :counters.new(1, [])

      Req.Test.stub(@stub_key, fn conn ->
        :counters.add(counter, 1, 1)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, JSON.encode!(%{"error" => "overloaded"}))
      end)

      assert {:error, {:transient, 503, _}} = Gemini.complete("anything")
      assert :counters.get(counter, 1) == 1
    end
  end
end
