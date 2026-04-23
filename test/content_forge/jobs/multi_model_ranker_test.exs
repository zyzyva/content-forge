defmodule ContentForge.Jobs.MultiModelRankerTest do
  use ContentForge.DataCase, async: false
  use Oban.Testing, repo: ContentForge.Repo

  import ExUnit.CaptureLog

  alias ContentForge.ContentGeneration
  alias ContentForge.Jobs.MultiModelRanker
  alias ContentForge.Products

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

    {:ok, product} =
      Products.create_product(%{
        name: "Test Product",
        voice_profile: "professional"
      })

    %{product: product}
  end

  defp put_anthropic_cfg(cfg) do
    existing = Application.get_env(:content_forge, @llm_key, [])
    Application.put_env(:content_forge, @llm_key, Keyword.put(existing, :anthropic, cfg))
  end

  defp put_gemini_cfg(cfg) do
    existing = Application.get_env(:content_forge, @llm_key, [])
    Application.put_env(:content_forge, @llm_key, Keyword.put(existing, :gemini, cfg))
  end

  defp anthropic_text_response(text) do
    %{
      "id" => "msg_01",
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "text", "text" => text}],
      "model" => "claude-sonnet-4-6",
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 12, "output_tokens" => 34}
    }
  end

  defp gemini_text_response(text) do
    %{
      "candidates" => [
        %{
          "content" => %{"parts" => [%{"text" => text}], "role" => "model"},
          "finishReason" => "STOP"
        }
      ],
      "usageMetadata" => %{"totalTokenCount" => 42},
      "modelVersion" => "gemini-2.5-flash"
    }
  end

  defp scoring_json(%{accuracy: a, seo: s, eev: e, critique: c}) do
    JSON.encode!(%{
      "accuracy" => a,
      "seo" => s,
      "eev" => e,
      "critique" => c
    })
  end

  defp create_draft!(product, attrs) do
    defaults = %{
      product_id: product.id,
      content: "a post about the product",
      platform: "twitter",
      content_type: "post",
      angle: "educational",
      generating_model: "openclaw",
      status: "draft"
    }

    {:ok, draft} = ContentGeneration.create_draft(Map.merge(defaults, attrs))
    draft
  end

  describe "happy path: both providers configured" do
    test "scores each draft with both providers and promotes top N", %{product: product} do
      _draft_lo = create_draft!(product, %{content: "weak draft", angle: "educational"})
      _draft_hi = create_draft!(product, %{content: "strong draft", angle: "humor"})

      Req.Test.stub(@anthropic_stub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        {:ok, decoded} = JSON.decode(body)
        [%{"content" => user_text}] = decoded["messages"]

        scores =
          if user_text =~ "weak draft" do
            %{accuracy: 5.0, seo: 4.0, eev: 5.0, critique: "weak"}
          else
            %{accuracy: 9.0, seo: 8.0, eev: 9.0, critique: "strong"}
          end

        Req.Test.json(conn, anthropic_text_response(scoring_json(scores)))
      end)

      Req.Test.stub(@gemini_stub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        {:ok, decoded} = JSON.decode(body)
        [%{"parts" => [%{"text" => user_text}]}] = decoded["contents"]

        scores =
          if user_text =~ "weak draft" do
            %{accuracy: 5.5, seo: 4.5, eev: 5.5, critique: "weak"}
          else
            %{accuracy: 9.5, seo: 8.5, eev: 9.5, critique: "strong"}
          end

        Req.Test.json(conn, gemini_text_response(scoring_json(scores)))
      end)

      assert {:ok, _} =
               perform_job(MultiModelRanker, %{
                 "product_id" => product.id,
                 "content_type" => "post",
                 "top_n" => 1
               })

      drafts = ContentGeneration.list_drafts_by_type(product.id, "post")
      ranked = Enum.filter(drafts, fn d -> d.status == "ranked" end)

      assert length(ranked) == 1
      assert hd(ranked).content == "strong draft"

      [strong | _] = ranked

      claude_score = ContentGeneration.get_score_for_draft_by_model(strong.id, "claude")
      gemini_score = ContentGeneration.get_score_for_draft_by_model(strong.id, "gemini")

      assert claude_score.accuracy_score == 9.0
      assert claude_score.critique == "strong"
      assert gemini_score.accuracy_score == 9.5
    end
  end

  describe "one provider configured" do
    test "Anthropic-only: only Anthropic scores exist, promotion still happens",
         %{product: product} do
      put_gemini_cfg(gemini_cfg_unset())

      draft = create_draft!(product, %{content: "solo draft"})

      test_pid = self()

      Req.Test.stub(@gemini_stub, fn _conn ->
        send(test_pid, :unexpected_gemini_http)
        raise "Gemini must not be called when not configured"
      end)

      Req.Test.stub(@anthropic_stub, fn conn ->
        Req.Test.json(
          conn,
          anthropic_text_response(
            scoring_json(%{accuracy: 8.0, seo: 7.5, eev: 8.0, critique: "solid"})
          )
        )
      end)

      assert {:ok, _} =
               perform_job(MultiModelRanker, %{
                 "product_id" => product.id,
                 "content_type" => "post",
                 "top_n" => 1
               })

      refute_received :unexpected_gemini_http

      assert ContentGeneration.get_score_for_draft_by_model(draft.id, "claude")
      refute ContentGeneration.get_score_for_draft_by_model(draft.id, "gemini")

      updated = ContentGeneration.get_draft!(draft.id)
      assert updated.status == "ranked"
    end

    test "Gemini-only: only Gemini scores exist, promotion still happens",
         %{product: product} do
      put_anthropic_cfg(anthropic_cfg_unset())

      draft = create_draft!(product, %{content: "solo gemini draft"})

      test_pid = self()

      Req.Test.stub(@anthropic_stub, fn _conn ->
        send(test_pid, :unexpected_anthropic_http)
        raise "Anthropic must not be called when not configured"
      end)

      Req.Test.stub(@gemini_stub, fn conn ->
        Req.Test.json(
          conn,
          gemini_text_response(scoring_json(%{accuracy: 7.5, seo: 8.0, eev: 7.0, critique: "ok"}))
        )
      end)

      assert {:ok, _} =
               perform_job(MultiModelRanker, %{
                 "product_id" => product.id,
                 "content_type" => "post",
                 "top_n" => 1
               })

      refute_received :unexpected_anthropic_http

      refute ContentGeneration.get_score_for_draft_by_model(draft.id, "claude")
      assert ContentGeneration.get_score_for_draft_by_model(draft.id, "gemini")

      updated = ContentGeneration.get_draft!(draft.id)
      assert updated.status == "ranked"
    end
  end

  describe "neither provider configured" do
    test "skips scoring without promoting any draft", %{product: product} do
      put_anthropic_cfg(anthropic_cfg_unset())
      put_gemini_cfg(gemini_cfg_unset())

      draft = create_draft!(product, %{content: "unscored draft"})

      test_pid = self()

      Req.Test.stub(@anthropic_stub, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no HTTP expected"
      end)

      Req.Test.stub(@gemini_stub, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no HTTP expected"
      end)

      log =
        capture_log(fn ->
          assert {:ok, _} =
                   perform_job(MultiModelRanker, %{
                     "product_id" => product.id,
                     "content_type" => "post",
                     "top_n" => 1
                   })
        end)

      refute_received :unexpected_http
      assert log =~ "LLM unavailable"

      updated = ContentGeneration.get_draft!(draft.id)
      assert updated.status == "draft"
      refute ContentGeneration.get_score_for_draft_by_model(draft.id, "claude")
      refute ContentGeneration.get_score_for_draft_by_model(draft.id, "gemini")
    end
  end

  describe "malformed JSON response" do
    test "malformed response from one provider yields no row for that provider; other still scores",
         %{product: product} do
      draft = create_draft!(product, %{content: "malformed-test draft"})

      Req.Test.stub(@anthropic_stub, fn conn ->
        Req.Test.json(conn, anthropic_text_response("not actually json at all"))
      end)

      Req.Test.stub(@gemini_stub, fn conn ->
        Req.Test.json(
          conn,
          gemini_text_response(scoring_json(%{accuracy: 8.0, seo: 7.0, eev: 8.0, critique: "ok"}))
        )
      end)

      log =
        capture_log(fn ->
          assert {:ok, _} =
                   perform_job(MultiModelRanker, %{
                     "product_id" => product.id,
                     "content_type" => "post",
                     "top_n" => 1
                   })
        end)

      assert log =~ "parse" or log =~ "malformed"

      refute ContentGeneration.get_score_for_draft_by_model(draft.id, "claude")
      assert ContentGeneration.get_score_for_draft_by_model(draft.id, "gemini")
    end
  end

  describe "transient error" do
    test "503 from Anthropic returns {:error, _} so Oban retries",
         %{product: product} do
      _draft = create_draft!(product, %{content: "retry me"})

      Req.Test.stub(@anthropic_stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, JSON.encode!(%{"error" => "overloaded"}))
      end)

      Req.Test.stub(@gemini_stub, fn conn ->
        Req.Test.json(
          conn,
          gemini_text_response(scoring_json(%{accuracy: 8.0, seo: 7.0, eev: 8.0, critique: "ok"}))
        )
      end)

      log =
        capture_log(fn ->
          assert {:error, _reason} =
                   perform_job(MultiModelRanker, %{
                     "product_id" => product.id,
                     "content_type" => "post",
                     "top_n" => 1
                   })
        end)

      assert log =~ "transient" or log =~ "503"
    end
  end

  # --- helpers --------------------------------------------------------------

  defp anthropic_cfg_unset, do: Keyword.put(current_anthropic(), :api_key, nil)
  defp gemini_cfg_unset, do: Keyword.put(current_gemini(), :api_key, nil)

  defp current_anthropic, do: Application.get_env(:content_forge, @llm_key)[:anthropic]
  defp current_gemini, do: Application.get_env(:content_forge, @llm_key)[:gemini]
end
