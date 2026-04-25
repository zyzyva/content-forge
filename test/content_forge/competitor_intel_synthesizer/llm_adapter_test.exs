defmodule ContentForge.CompetitorIntelSynthesizer.LLMAdapterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ContentForge.CompetitorIntelSynthesizer.LLMAdapter
  alias ContentForge.Products.CompetitorPost

  @llm_key :llm
  @anthropic_stub ContentForge.LLM.Anthropic

  setup do
    original = Application.get_env(:content_forge, @llm_key, [])

    on_exit(fn ->
      Application.put_env(:content_forge, @llm_key, original)
    end)

    existing_rest = Keyword.delete(original, :anthropic)

    Application.put_env(
      :content_forge,
      @llm_key,
      [
        anthropic: [
          base_url: "http://anthropic.test",
          api_key: "sk-test-key",
          default_model: "claude-sonnet-4-6",
          max_tokens: 1024,
          req_options: [plug: {Req.Test, @anthropic_stub}]
        ]
      ] ++ existing_rest
    )

    :ok
  end

  defp put_anthropic_cfg(cfg) do
    existing = Application.get_env(:content_forge, @llm_key, [])
    Application.put_env(:content_forge, @llm_key, Keyword.put(existing, :anthropic, cfg))
  end

  defp current_anthropic, do: Application.get_env(:content_forge, @llm_key)[:anthropic]

  defp anthropic_response(text, model \\ "claude-sonnet-4-6") do
    %{
      "id" => "msg_01",
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "text", "text" => text}],
      "model" => model,
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 123, "output_tokens" => 456}
    }
  end

  defp sample_posts do
    [
      %CompetitorPost{
        post_id: "p1",
        content: "before and after thread",
        post_url: "https://example.com/1",
        likes_count: 500,
        comments_count: 50,
        shares_count: 20,
        engagement_score: 4.2,
        posted_at: ~U[2026-04-20 10:00:00Z]
      },
      %CompetitorPost{
        post_id: "p2",
        content: "funny skit",
        post_url: "https://example.com/2",
        likes_count: 400,
        comments_count: 40,
        shares_count: 10,
        engagement_score: 3.1,
        posted_at: ~U[2026-04-19 10:00:00Z]
      }
    ]
  end

  defp intel_json do
    JSON.encode!(%{
      "summary" => "Before-and-afters and humor are dominating the niche this cycle.",
      "trending_topics" => ["before/after", "humor", "case studies"],
      "winning_formats" => ["threads", "short video skits"],
      "effective_hooks" => ["you won't believe", "3 things nobody tells you"]
    })
  end

  describe "happy path" do
    test "returns a parsed intel map from a structured JSON reply" do
      Req.Test.stub(@anthropic_stub, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/messages"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        {:ok, decoded} = JSON.decode(body)

        [%{"content" => user_prompt}] = decoded["messages"]
        assert user_prompt =~ "before and after thread"
        assert user_prompt =~ "funny skit"
        assert decoded["system"] =~ "JSON"

        Req.Test.json(conn, anthropic_response(intel_json()))
      end)

      assert {:ok, intel} = LLMAdapter.summarize(sample_posts())

      assert intel.summary =~ "Before-and-afters"
      assert intel.trending_topics == ["before/after", "humor", "case studies"]
      assert intel.winning_formats == ["threads", "short video skits"]
      assert intel.effective_hooks == ["you won't believe", "3 things nobody tells you"]
    end

    test "parses JSON wrapped in a fenced code block" do
      fenced =
        """
        Here is the intel you asked for:

        ```json
        #{intel_json()}
        ```

        Let me know if you want more.
        """

      Req.Test.stub(@anthropic_stub, fn conn ->
        Req.Test.json(conn, anthropic_response(fenced))
      end)

      assert {:ok, intel} = LLMAdapter.summarize(sample_posts())
      assert intel.summary =~ "Before-and-afters"
      assert length(intel.trending_topics) == 3
    end

    test "empty post list still yields a well-formed error (defensive)" do
      test_pid = self()

      Req.Test.stub(@anthropic_stub, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no HTTP expected for empty post list"
      end)

      assert {:error, :no_posts} = LLMAdapter.summarize([])
      refute_received :unexpected_http
    end
  end

  describe "malformed responses" do
    test "plain-text reply (not JSON) is rejected without fabrication" do
      Req.Test.stub(@anthropic_stub, fn conn ->
        Req.Test.json(conn, anthropic_response("sorry I cannot produce JSON today"))
      end)

      log =
        capture_log(fn ->
          assert {:error, :malformed_response} = LLMAdapter.summarize(sample_posts())
        end)

      assert log =~ "parse" or log =~ "malformed"
    end

    test "JSON missing a required field is rejected" do
      missing_summary =
        JSON.encode!(%{
          "trending_topics" => ["x"],
          "winning_formats" => ["y"],
          "effective_hooks" => ["z"]
        })

      Req.Test.stub(@anthropic_stub, fn conn ->
        Req.Test.json(conn, anthropic_response(missing_summary))
      end)

      log =
        capture_log(fn ->
          assert {:error, :malformed_response} = LLMAdapter.summarize(sample_posts())
        end)

      assert log =~ "parse" or log =~ "malformed"
    end

    test "JSON with wrong types in array fields is rejected" do
      bad_types =
        JSON.encode!(%{
          "summary" => "ok summary",
          "trending_topics" => "not an array",
          "winning_formats" => [],
          "effective_hooks" => []
        })

      Req.Test.stub(@anthropic_stub, fn conn ->
        Req.Test.json(conn, anthropic_response(bad_types))
      end)

      log =
        capture_log(fn ->
          assert {:error, :malformed_response} = LLMAdapter.summarize(sample_posts())
        end)

      assert log =~ "parse" or log =~ "malformed"
    end
  end

  describe "LLM unavailable" do
    test "missing Anthropic key passes {:error, :not_configured} through" do
      cfg = current_anthropic() |> Keyword.put(:api_key, nil)
      put_anthropic_cfg(cfg)

      test_pid = self()

      Req.Test.stub(@anthropic_stub, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no HTTP expected when Anthropic is not configured"
      end)

      assert {:error, :not_configured} = LLMAdapter.summarize(sample_posts())
      refute_received :unexpected_http
    end
  end

  describe "error classification" do
    test "503 transient propagates so Oban can retry" do
      Req.Test.stub(@anthropic_stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, JSON.encode!(%{"error" => "overloaded"}))
      end)

      assert {:error, {:transient, 503, _}} = LLMAdapter.summarize(sample_posts())
    end

    test "429 rate limit propagates as transient" do
      Req.Test.stub(@anthropic_stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(429, JSON.encode!(%{"error" => "rate_limit"}))
      end)

      assert {:error, {:transient, 429, _}} = LLMAdapter.summarize(sample_posts())
    end

    test "400 permanent propagates" do
      Req.Test.stub(@anthropic_stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, JSON.encode!(%{"error" => "invalid"}))
      end)

      assert {:error, {:http_error, 400, _}} = LLMAdapter.summarize(sample_posts())
    end
  end

  describe "Phase 17.4 comment-aware prompt + audience_signals" do
    alias ContentForge.Products.CompetitorPostComment

    defp intel_json_with_signals do
      JSON.encode!(%{
        "summary" => "rivals are leaning on case studies",
        "trending_topics" => ["case studies"],
        "winning_formats" => ["carousels"],
        "effective_hooks" => ["before / after"],
        "audience_signals" => ["asks for pricing", "skeptical of guarantees"]
      })
    end

    defp post_with_comments do
      %CompetitorPost{
        post_id: "p-comm",
        content: "case study reveal",
        post_url: "https://example.com/case",
        likes_count: 4_200,
        comments_count: 311,
        shares_count: 950,
        engagement_score: 5.0,
        posted_at: ~U[2026-04-21 12:00:00Z],
        comments: [
          %CompetitorPostComment{
            platform_comment_id: "c1",
            author_handle: "fan42",
            text: "love this, but how much does it cost?",
            likes_count: 75
          },
          %CompetitorPostComment{
            platform_comment_id: "c2",
            author_handle: "skeptic",
            text: "the guarantee section is suspicious",
            likes_count: 30
          },
          %CompetitorPostComment{
            platform_comment_id: "c3",
            author_handle: "noise",
            text: "ok",
            likes_count: 1
          }
        ]
      }
    end

    test "comment threads are included in the user prompt" do
      ref = make_ref()
      test_pid = self()

      Req.Test.stub(@anthropic_stub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        {:ok, decoded} = JSON.decode(body)
        [%{"content" => user_prompt}] = decoded["messages"]
        send(test_pid, {ref, :user_prompt, user_prompt})
        Req.Test.json(conn, anthropic_response(intel_json_with_signals()))
      end)

      assert {:ok, _intel} = LLMAdapter.summarize([post_with_comments()])

      assert_receive {^ref, :user_prompt, prompt}
      assert prompt =~ "Top comments (by likes):"
      assert prompt =~ "@fan42 (75 likes): love this"
      assert prompt =~ "@skeptic (30 likes): the guarantee section"
    end

    test "system prompt asks the LLM for audience_signals" do
      ref = make_ref()
      test_pid = self()

      Req.Test.stub(@anthropic_stub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        {:ok, decoded} = JSON.decode(body)
        send(test_pid, {ref, :system_prompt, decoded["system"]})
        Req.Test.json(conn, anthropic_response(intel_json_with_signals()))
      end)

      assert {:ok, _intel} = LLMAdapter.summarize([post_with_comments()])

      assert_receive {^ref, :system_prompt, system_prompt}
      assert system_prompt =~ "audience_signals"
    end

    test "audience_signals from the LLM reply make it into the parsed intel" do
      Req.Test.stub(@anthropic_stub, fn conn ->
        Req.Test.json(conn, anthropic_response(intel_json_with_signals()))
      end)

      assert {:ok, intel} = LLMAdapter.summarize([post_with_comments()])
      assert intel.audience_signals == ["asks for pricing", "skeptical of guarantees"]
    end

    test "audience_signals defaults to [] when LLM omits the key" do
      Req.Test.stub(@anthropic_stub, fn conn ->
        Req.Test.json(conn, anthropic_response(intel_json()))
      end)

      assert {:ok, intel} = LLMAdapter.summarize(sample_posts())
      assert intel.audience_signals == []
    end

    test "post without comments produces a prompt without a Top comments block" do
      ref = make_ref()
      test_pid = self()

      Req.Test.stub(@anthropic_stub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        {:ok, decoded} = JSON.decode(body)
        [%{"content" => user_prompt}] = decoded["messages"]
        send(test_pid, {ref, :user_prompt, user_prompt})
        Req.Test.json(conn, anthropic_response(intel_json()))
      end)

      assert {:ok, _intel} = LLMAdapter.summarize(sample_posts())

      assert_receive {^ref, :user_prompt, prompt}
      refute prompt =~ "Top comments (by likes):"
    end
  end
end
