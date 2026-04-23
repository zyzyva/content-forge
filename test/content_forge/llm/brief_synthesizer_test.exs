defmodule ContentForge.LLM.BriefSynthesizerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ContentForge.LLM.BriefSynthesizer

  @llm_key :llm
  @anthropic_stub ContentForge.LLM.Anthropic
  @gemini_stub ContentForge.LLM.Gemini

  setup do
    original = Application.get_env(:content_forge, @llm_key, [])

    on_exit(fn ->
      Application.put_env(:content_forge, @llm_key, original)
    end)

    Application.put_env(:content_forge, @llm_key,
      anthropic: [
        base_url: "http://anthropic.test",
        api_key: "sk-test-anthropic",
        default_model: "claude-sonnet-4-6",
        max_tokens: 1024,
        req_options: [plug: {Req.Test, @anthropic_stub}]
      ],
      gemini: [
        base_url: "http://gemini.test",
        api_key: "gk-test-gemini",
        default_model: "gemini-2.5-flash",
        max_tokens: 1024,
        req_options: [plug: {Req.Test, @gemini_stub}]
      ]
    )

    :ok
  end

  defp anthropic_cfg, do: Application.get_env(:content_forge, @llm_key)[:anthropic]
  defp gemini_cfg, do: Application.get_env(:content_forge, @llm_key)[:gemini]

  defp put_anthropic_cfg(cfg) do
    existing = Application.get_env(:content_forge, @llm_key, [])
    Application.put_env(:content_forge, @llm_key, Keyword.put(existing, :anthropic, cfg))
  end

  defp put_gemini_cfg(cfg) do
    existing = Application.get_env(:content_forge, @llm_key, [])
    Application.put_env(:content_forge, @llm_key, Keyword.put(existing, :gemini, cfg))
  end

  defp anthropic_response(text, model \\ "claude-sonnet-4-6") do
    %{
      "id" => "msg_01",
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "text", "text" => text}],
      "model" => model,
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 12, "output_tokens" => 34}
    }
  end

  defp gemini_response(text, model \\ "gemini-2.5-flash") do
    %{
      "candidates" => [
        %{
          "content" => %{"parts" => [%{"text" => text}], "role" => "model"},
          "finishReason" => "STOP"
        }
      ],
      "usageMetadata" => %{"totalTokenCount" => 42},
      "modelVersion" => model
    }
  end

  describe "both providers configured" do
    test "queries both in parallel and synthesizes via a final Anthropic call" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(@anthropic_stub, fn conn ->
        Agent.update(counter, &(&1 + 1))
        call_number = Agent.get(counter, & &1)

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        {:ok, decoded} = JSON.decode(body)
        [%{"content" => user_text}] = decoded["messages"]

        case call_number do
          1 ->
            assert user_text =~ "ORIGINAL USER PROMPT"
            Req.Test.json(conn, anthropic_response("Anthropic draft body", "claude-opus-4-7"))

          2 ->
            assert user_text =~ "Draft A (Anthropic)"
            assert user_text =~ "Anthropic draft body"
            assert user_text =~ "Draft B (Gemini)"
            assert user_text =~ "Gemini draft body"
            Req.Test.json(conn, anthropic_response("Synthesized brief", "claude-sonnet-4-6"))
        end
      end)

      Req.Test.stub(@gemini_stub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        {:ok, decoded} = JSON.decode(body)
        [%{"parts" => [%{"text" => user_text}]}] = decoded["contents"]
        assert user_text =~ "ORIGINAL USER PROMPT"

        Req.Test.json(conn, gemini_response("Gemini draft body", "gemini-2.5-flash"))
      end)

      assert {:ok, text, model_descriptor} =
               BriefSynthesizer.generate("ORIGINAL USER PROMPT", "system prompt")

      assert text == "Synthesized brief"
      assert model_descriptor =~ "synthesis"
      assert model_descriptor =~ "anthropic:claude-opus-4-7"
      assert model_descriptor =~ "gemini:gemini-2.5-flash"
      assert model_descriptor =~ "claude-sonnet-4-6"

      assert Agent.get(counter, & &1) == 2
    end
  end

  describe "single provider configured" do
    test "Anthropic only: uses Anthropic directly with no synthesis" do
      cfg = gemini_cfg() |> Keyword.put(:api_key, nil)
      put_gemini_cfg(cfg)

      test_pid = self()

      Req.Test.stub(@gemini_stub, fn _conn ->
        send(test_pid, :unexpected_gemini_http)
        raise "Gemini must not be called when not configured"
      end)

      Req.Test.stub(@anthropic_stub, fn conn ->
        Req.Test.json(conn, anthropic_response("Anthropic-only brief", "claude-sonnet-4-6"))
      end)

      assert {:ok, "Anthropic-only brief", model} =
               BriefSynthesizer.generate("prompt", "system")

      assert model == "anthropic:claude-sonnet-4-6"
      refute_received :unexpected_gemini_http
    end

    test "Gemini only: uses Gemini directly with no synthesis" do
      cfg = anthropic_cfg() |> Keyword.put(:api_key, nil)
      put_anthropic_cfg(cfg)

      test_pid = self()

      Req.Test.stub(@anthropic_stub, fn _conn ->
        send(test_pid, :unexpected_anthropic_http)
        raise "Anthropic must not be called when not configured"
      end)

      Req.Test.stub(@gemini_stub, fn conn ->
        Req.Test.json(conn, gemini_response("Gemini-only brief", "gemini-2.5-flash"))
      end)

      assert {:ok, "Gemini-only brief", model} = BriefSynthesizer.generate("prompt", "system")
      assert model == "gemini:gemini-2.5-flash"
      refute_received :unexpected_anthropic_http
    end
  end

  describe "neither provider configured" do
    test "returns {:error, :not_configured} without any HTTP" do
      cfg_a = anthropic_cfg() |> Keyword.put(:api_key, nil)
      cfg_g = gemini_cfg() |> Keyword.put(:api_key, nil)
      put_anthropic_cfg(cfg_a)
      put_gemini_cfg(cfg_g)

      test_pid = self()

      Req.Test.stub(@anthropic_stub, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no HTTP expected"
      end)

      Req.Test.stub(@gemini_stub, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no HTTP expected"
      end)

      assert {:error, :not_configured} = BriefSynthesizer.generate("prompt", "system")
      refute_received :unexpected_http
    end
  end

  describe "partial failure: one succeeds, other transient fails" do
    test "Anthropic succeeds, Gemini transient fails: returns Anthropic with metadata note" do
      Req.Test.stub(@anthropic_stub, fn conn ->
        Req.Test.json(conn, anthropic_response("Anthropic draft", "claude-sonnet-4-6"))
      end)

      Req.Test.stub(@gemini_stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, JSON.encode!(%{"error" => "overloaded"}))
      end)

      log =
        capture_log(fn ->
          assert {:ok, "Anthropic draft", model} =
                   BriefSynthesizer.generate("prompt", "system")

          assert model == "anthropic:claude-sonnet-4-6 (gemini unavailable)"
        end)

      assert log =~ "Gemini errored"
    end

    test "Gemini succeeds, Anthropic transient fails: returns Gemini with metadata note" do
      Req.Test.stub(@anthropic_stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, JSON.encode!(%{"error" => "overloaded"}))
      end)

      Req.Test.stub(@gemini_stub, fn conn ->
        Req.Test.json(conn, gemini_response("Gemini draft", "gemini-2.5-flash"))
      end)

      log =
        capture_log(fn ->
          assert {:ok, "Gemini draft", model} =
                   BriefSynthesizer.generate("prompt", "system")

          assert model == "gemini:gemini-2.5-flash (anthropic unavailable)"
        end)

      assert log =~ "Anthropic errored"
    end
  end

  describe "both providers fail" do
    test "both transient fails propagate an error tuple so Oban retries" do
      Req.Test.stub(@anthropic_stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, JSON.encode!(%{"error" => "overloaded"}))
      end)

      Req.Test.stub(@gemini_stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, JSON.encode!(%{"error" => "internal"}))
      end)

      log =
        capture_log(fn ->
          assert {:error, {:transient, _, _}} = BriefSynthesizer.generate("prompt", "system")
        end)

      assert log =~ "both providers failed"
    end

    test "both permanent fails propagate a permanent error tuple so the job cancels" do
      Req.Test.stub(@anthropic_stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, JSON.encode!(%{"error" => %{"type" => "invalid_request_error"}}))
      end)

      Req.Test.stub(@gemini_stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, JSON.encode!(%{"error" => %{"status" => "INVALID_ARGUMENT"}}))
      end)

      log =
        capture_log(fn ->
          assert {:error, {:http_error, 400, _}} = BriefSynthesizer.generate("prompt", "system")
        end)

      assert log =~ "both providers failed"
    end
  end

  describe "synthesis step failure" do
    test "third Anthropic call failing after both drafts succeed returns that error" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(@anthropic_stub, fn conn ->
        Agent.update(counter, &(&1 + 1))
        call_number = Agent.get(counter, & &1)

        case call_number do
          1 ->
            Req.Test.json(conn, anthropic_response("draft A"))

          2 ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(503, JSON.encode!(%{"error" => "overloaded"}))
        end
      end)

      Req.Test.stub(@gemini_stub, fn conn ->
        Req.Test.json(conn, gemini_response("draft B"))
      end)

      log =
        capture_log(fn ->
          assert {:error, {:transient, 503, _}} =
                   BriefSynthesizer.generate("prompt", "system")
        end)

      assert log =~ "synthesis step failed"
    end
  end

  describe "partial failure: one succeeds, other permanent fails (same fallback rule)" do
    test "Anthropic succeeds, Gemini 400 permanent: Gemini error does not escalate" do
      Req.Test.stub(@anthropic_stub, fn conn ->
        Req.Test.json(conn, anthropic_response("Anthropic draft", "claude-sonnet-4-6"))
      end)

      Req.Test.stub(@gemini_stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, JSON.encode!(%{"error" => %{"status" => "INVALID_ARGUMENT"}}))
      end)

      log =
        capture_log(fn ->
          assert {:ok, "Anthropic draft", model} =
                   BriefSynthesizer.generate("prompt", "system")

          assert model =~ "anthropic:"
          assert model =~ "gemini unavailable"
        end)

      assert log =~ "Gemini errored"
    end
  end
end
