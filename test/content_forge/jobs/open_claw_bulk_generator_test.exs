defmodule ContentForge.Jobs.OpenClawBulkGeneratorTest do
  @moduledoc """
  Phase 11.2L coverage: OpenClawBulkGenerator now dispatches
  through `LLM.Anthropic.complete/2` for bulk variant
  generation. Three LLM calls per run (social, blog, video).
  """
  use ContentForge.DataCase, async: false
  use Oban.Testing, repo: ContentForge.Repo

  import ExUnit.CaptureLog

  alias ContentForge.ContentGeneration
  alias ContentForge.Jobs.OpenClawBulkGenerator
  alias ContentForge.Products

  @llm_key :llm
  @anthropic_stub ContentForge.LLM.Anthropic

  setup do
    original = Application.get_env(:content_forge, @llm_key, [])

    on_exit(fn ->
      Application.put_env(:content_forge, @llm_key, original)
    end)

    {:ok, product} =
      Products.create_product(%{name: "Bulk Product", voice_profile: "professional"})

    {:ok, brief} =
      ContentGeneration.create_content_brief(%{
        product_id: product.id,
        version: 1,
        content: "Do a thing. Stats: 42%, 2026.",
        model_used: "test"
      })

    %{product: product, brief: brief}
  end

  defp configure_anthropic do
    Application.put_env(:content_forge, @llm_key,
      anthropic: [
        base_url: "http://anthropic.test",
        api_key: "sk-test-anthropic",
        default_model: "claude-sonnet-4-6",
        max_tokens: 1024,
        req_options: [plug: {Req.Test, @anthropic_stub}]
      ]
    )
  end

  defp deconfigure_anthropic do
    Application.put_env(:content_forge, @llm_key, anthropic: [api_key: nil])
  end

  defp anthropic_response(text, model \\ "claude-sonnet-4-6") do
    %{
      "id" => "msg_01",
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "text", "text" => text}],
      "model" => model,
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    }
  end

  defp social_payload do
    %{
      "platforms" => %{
        "twitter" => [
          %{"angle" => "educational", "content" => "twitter educational variant"},
          %{"angle" => "humor", "content" => "twitter humor variant"}
        ],
        "linkedin" => [%{"angle" => "humor", "content" => "linkedin humor variant"}],
        "reddit" => [],
        "facebook" => [],
        "instagram" => []
      }
    }
  end

  defp blog_payload do
    %{
      "variants" => [
        %{
          "angle" => "humor",
          "content" =>
            "# Stripe Fees: Laughs and Numbers\n\nStripe: 2.9% + $0.30 per charge, 3-5 day payout. Published Feb 2026.\n\nBody.\n"
        }
      ]
    }
  end

  defp video_payload do
    %{
      "variants" => [
        %{"angle" => "humor", "content" => "Script: opening hook with jokes."}
      ]
    }
  end

  defp stub_anthropic_sequence(responses) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(@anthropic_stub, fn conn ->
      Agent.update(counter, &(&1 + 1))
      idx = Agent.get(counter, & &1)

      payload =
        responses
        |> Enum.at(idx - 1)
        |> case do
          nil -> raise "unexpected LLM call beyond stubbed sequence"
          other -> other
        end

      Req.Test.json(conn, anthropic_response(JSON.encode!(payload)))
    end)
  end

  describe "happy path" do
    test "creates drafts across social/blog/video from 3 LLM calls",
         %{product: product} do
      configure_anthropic()

      stub_anthropic_sequence([social_payload(), blog_payload(), video_payload()])

      assert {:ok, %{drafts_created: total}} =
               perform_job(OpenClawBulkGenerator, %{"product_id" => product.id})

      assert total > 0

      all = ContentGeneration.list_drafts()
      assert Enum.any?(all, &(&1.platform == "twitter" and &1.content_type == "post"))
      assert Enum.any?(all, &(&1.platform == "blog" and &1.content_type == "blog"))
      assert Enum.any?(all, &(&1.platform == "youtube" and &1.content_type == "video_script"))
    end

    test "humor angle appears across every content family",
         %{product: product} do
      configure_anthropic()
      stub_anthropic_sequence([social_payload(), blog_payload(), video_payload()])

      perform_job(OpenClawBulkGenerator, %{"product_id" => product.id})
      all = ContentGeneration.list_drafts()

      assert Enum.any?(all, &(&1.angle == "humor" and &1.content_type == "post"))
      assert Enum.any?(all, &(&1.angle == "humor" and &1.content_type == "blog"))
      assert Enum.any?(all, &(&1.angle == "humor" and &1.content_type == "video_script"))
    end

    test "generating_model is anthropic:<model-name> (not openclaw)",
         %{product: product} do
      configure_anthropic()
      stub_anthropic_sequence([social_payload(), blog_payload(), video_payload()])

      perform_job(OpenClawBulkGenerator, %{"product_id" => product.id})

      all = ContentGeneration.list_drafts()
      assert Enum.all?(all, fn d -> String.starts_with?(d.generating_model, "anthropic:") end)
    end
  end

  describe "missing config" do
    test "returns :skipped with zero drafts when Anthropic is not configured",
         %{product: product} do
      deconfigure_anthropic()

      capture_log(fn ->
        assert {:ok, :skipped} =
                 perform_job(OpenClawBulkGenerator, %{"product_id" => product.id})
      end)

      assert ContentGeneration.list_drafts() == []
    end
  end

  describe "malformed output" do
    test "cancels with 'malformed LLM output' when JSON is unparseable",
         %{product: product} do
      configure_anthropic()

      Req.Test.stub(@anthropic_stub, fn conn ->
        Req.Test.json(conn, anthropic_response("this is not JSON"))
      end)

      capture_log(fn ->
        assert {:cancel, "malformed LLM output"} =
                 perform_job(OpenClawBulkGenerator, %{"product_id" => product.id})
      end)
    end
  end

  describe "transient errors" do
    test "retries on 500 via Oban error return",
         %{product: product} do
      configure_anthropic()

      Req.Test.stub(@anthropic_stub, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => %{"type" => "overloaded", "message" => "boom"}})
      end)

      capture_log(fn ->
        assert {:error, {:transient, _, _}} =
                 perform_job(OpenClawBulkGenerator, %{"product_id" => product.id})
      end)
    end
  end

  describe "no brief" do
    test "cancels when no content brief exists", %{product: product} do
      configure_anthropic()

      # Clean out the brief inserted in setup.
      ContentGeneration.list_content_briefs()
      |> Enum.each(&ContentGeneration.delete_content_brief/1)

      capture_log(fn ->
        assert {:cancel, "No content brief found"} =
                 perform_job(OpenClawBulkGenerator, %{"product_id" => product.id})
      end)
    end
  end
end
