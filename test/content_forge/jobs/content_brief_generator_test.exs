defmodule ContentForge.Jobs.ContentBriefGeneratorTest do
  use ContentForge.DataCase, async: false
  use Oban.Testing, repo: ContentForge.Repo

  import ExUnit.CaptureLog

  alias ContentForge.ContentGeneration
  alias ContentForge.Jobs.ContentBriefGenerator
  alias ContentForge.Products

  @llm_key :llm
  @stub_key ContentForge.LLM.Anthropic

  setup do
    original = Application.get_env(:content_forge, @llm_key, [])

    on_exit(fn ->
      Application.put_env(:content_forge, @llm_key, original)
    end)

    Application.put_env(:content_forge, @llm_key,
      anthropic: [
        base_url: "http://anthropic.test",
        api_key: "sk-test-key",
        default_model: "claude-sonnet-4-6",
        max_tokens: 1024,
        req_options: [plug: {Req.Test, @stub_key}]
      ]
    )

    {:ok, product} =
      Products.create_product(%{
        name: "Test Product",
        voice_profile: "professional"
      })

    %{product: product}
  end

  defp anthropic_cfg, do: Application.get_env(:content_forge, @llm_key)[:anthropic]

  defp put_anthropic_cfg(cfg), do: Application.put_env(:content_forge, @llm_key, anthropic: cfg)

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

  describe "initial brief generation" do
    test "happy path writes the LLM text as brief content and records the actual model used",
         %{product: product} do
      Req.Test.stub(@stub_key, fn conn ->
        assert conn.request_path == "/v1/messages"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        {:ok, decoded} = JSON.decode(body)

        [user_turn] = decoded["messages"]
        assert user_turn["role"] == "user"
        assert user_turn["content"] =~ "Test Product"
        assert user_turn["content"] =~ "professional"
        assert decoded["system"] =~ "content strategist"

        Req.Test.json(
          conn,
          assistant_response("# Real content brief body", %{
            "model" => "claude-sonnet-4-6-20250929"
          })
        )
      end)

      assert {:ok, brief} =
               perform_job(ContentBriefGenerator, %{"product_id" => product.id})

      assert brief.content == "# Real content brief body"
      assert brief.model_used == "anthropic:claude-sonnet-4-6-20250929"
      assert brief.version == 1
      assert brief.product_id == product.id
      refute brief.content =~ "[To be determined"
      refute brief.content =~ "placeholder"
    end

    test "existing brief short-circuits without any LLM call when force_rewrite is false",
         %{product: product} do
      {:ok, _brief} =
        ContentGeneration.create_content_brief(%{
          product_id: product.id,
          version: 1,
          content: "existing brief",
          model_used: "claude-sonnet-4-6"
        })

      test_pid = self()

      Req.Test.stub(@stub_key, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no LLM call expected when an existing brief is present"
      end)

      assert {:ok, _} = perform_job(ContentBriefGenerator, %{"product_id" => product.id})

      refute_received :unexpected_http
    end
  end

  describe "brief rewrite with force_rewrite" do
    test "records the LLM text as a new version and bumps model_used",
         %{product: product} do
      {:ok, _brief} =
        ContentGeneration.create_content_brief(%{
          product_id: product.id,
          version: 1,
          content: "stale brief body",
          model_used: "claude-sonnet-4-6"
        })

      Req.Test.stub(@stub_key, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        {:ok, decoded} = JSON.decode(body)

        [user_turn] = decoded["messages"]
        assert user_turn["content"] =~ "stale brief body"
        assert user_turn["content"] =~ "Performance"

        Req.Test.json(
          conn,
          assistant_response("# Rewritten brief body", %{
            "model" => "claude-opus-4-7"
          })
        )
      end)

      assert {:ok, new_brief} =
               perform_job(ContentBriefGenerator, %{
                 "product_id" => product.id,
                 "force_rewrite" => true
               })

      assert new_brief.content == "# Rewritten brief body"
      assert new_brief.model_used == "anthropic:claude-opus-4-7"
      assert new_brief.version == 2
    end
  end

  describe "LLM unavailable" do
    test "missing API key returns {:ok, :skipped}, logs, and writes no brief record",
         %{product: product} do
      cfg = anthropic_cfg() |> Keyword.put(:api_key, nil)
      put_anthropic_cfg(cfg)

      test_pid = self()

      Req.Test.stub(@stub_key, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no HTTP expected when LLM is not configured"
      end)

      log =
        capture_log(fn ->
          assert {:ok, :skipped} =
                   perform_job(ContentBriefGenerator, %{"product_id" => product.id})
        end)

      refute_received :unexpected_http
      assert log =~ "LLM unavailable"

      assert ContentGeneration.get_latest_content_brief_for_product(product.id) == nil
    end
  end

  describe "error classification" do
    test "transient error propagates as {:error, _} so Oban retries",
         %{product: product} do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, JSON.encode!(%{"error" => "overloaded"}))
      end)

      log =
        capture_log(fn ->
          assert {:error, {:transient, 503, _body}} =
                   perform_job(ContentBriefGenerator, %{"product_id" => product.id})
        end)

      assert log =~ "transient" or log =~ "503"

      assert ContentGeneration.get_latest_content_brief_for_product(product.id) == nil
    end

    test "429 rate limit propagates as {:error, _} so Oban retries",
         %{product: product} do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(429, JSON.encode!(%{"error" => %{"type" => "rate_limit_error"}}))
      end)

      log =
        capture_log(fn ->
          assert {:error, {:transient, 429, _body}} =
                   perform_job(ContentBriefGenerator, %{"product_id" => product.id})
        end)

      assert log =~ "429" or log =~ "transient"
    end

    test "permanent 400 error cancels the job with error recorded",
         %{product: product} do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, JSON.encode!(%{"error" => %{"type" => "invalid_request_error"}}))
      end)

      log =
        capture_log(fn ->
          assert {:cancel, reason} =
                   perform_job(ContentBriefGenerator, %{"product_id" => product.id})

          assert reason =~ "400" or reason =~ "LLM"
        end)

      assert log =~ "400" or log =~ "rejected"

      assert ContentGeneration.get_latest_content_brief_for_product(product.id) == nil
    end
  end
end
