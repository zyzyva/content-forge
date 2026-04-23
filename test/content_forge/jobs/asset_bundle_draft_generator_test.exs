defmodule ContentForge.Jobs.AssetBundleDraftGeneratorTest do
  use ContentForge.DataCase, async: false
  use Oban.Testing, repo: ContentForge.Repo

  import ExUnit.CaptureLog

  alias ContentForge.ContentGeneration
  alias ContentForge.ContentGeneration.Draft
  alias ContentForge.Jobs.AssetBundleDraftGenerator
  alias ContentForge.ProductAssets
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
        max_tokens: 2048,
        req_options: [plug: {Req.Test, @stub_key}]
      ]
    )

    {:ok, product} =
      Products.create_product(%{name: "Test SaaS", voice_profile: "professional"})

    {:ok, bundle} =
      ProductAssets.create_bundle(%{
        product_id: product.id,
        name: "Johnson kitchen remodel",
        context: "Quartz counters, 3 weeks, custom cabinets"
      })

    {:ok, featured_asset} =
      ProductAssets.create_asset(%{
        product_id: product.id,
        storage_key: "products/#{product.id}/assets/hero.jpg",
        filename: "hero.jpg",
        mime_type: "image/jpeg",
        media_type: "image",
        byte_size: 10_240,
        uploaded_at: DateTime.utc_now(),
        description: "Finished kitchen hero shot",
        tags: ["hero", "kitchen"]
      })

    {:ok, second_asset} =
      ProductAssets.create_asset(%{
        product_id: product.id,
        storage_key: "products/#{product.id}/assets/wide.jpg",
        filename: "wide.jpg",
        mime_type: "image/jpeg",
        media_type: "image",
        byte_size: 8192,
        uploaded_at: DateTime.utc_now(),
        tags: ["context"]
      })

    {:ok, _} = ProductAssets.add_asset_to_bundle(bundle, featured_asset)
    {:ok, _} = ProductAssets.add_asset_to_bundle(bundle, second_asset)

    %{
      product: product,
      bundle: ProductAssets.get_bundle!(bundle.id),
      featured_asset: featured_asset
    }
  end

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

  defp variants_payload do
    %{
      "platforms" => %{
        "twitter" => [
          "Twitter variant 1 about kitchen",
          "Twitter variant 2 about kitchen"
        ],
        "linkedin" => [
          "LinkedIn variant 1 about custom cabinets",
          "LinkedIn variant 2 about custom cabinets"
        ]
      }
    }
  end

  defp encoded_variants, do: JSON.encode!(variants_payload())

  defp run_job(bundle, platforms, n) do
    perform_job(AssetBundleDraftGenerator, %{
      "bundle_id" => bundle.id,
      "platforms" => platforms,
      "variants_per_platform" => n
    })
  end

  defp run_job_with_args(args) do
    perform_job(AssetBundleDraftGenerator, args)
  end

  describe "happy path" do
    test "creates N drafts per platform tied to bundle with featured asset attached",
         %{bundle: bundle, featured_asset: featured_asset} do
      Req.Test.stub(@stub_key, fn conn ->
        assert conn.request_path == "/v1/messages"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        {:ok, decoded} = JSON.decode(body)

        [user_turn] = decoded["messages"]
        assert user_turn["content"] =~ bundle.name
        assert user_turn["content"] =~ "Quartz counters"
        assert user_turn["content"] =~ "hero.jpg"
        assert user_turn["content"] =~ "twitter"
        assert user_turn["content"] =~ "linkedin"
        assert decoded["system"] =~ "variants"

        Req.Test.json(
          conn,
          assistant_response(encoded_variants(), %{"model" => "claude-sonnet-4-6-20250929"})
        )
      end)

      assert {:ok, drafts} = run_job(bundle, ["twitter", "linkedin"], 2)
      assert length(drafts) == 4

      twitter_drafts = Enum.filter(drafts, &(&1.platform == "twitter"))
      linkedin_drafts = Enum.filter(drafts, &(&1.platform == "linkedin"))
      assert length(twitter_drafts) == 2
      assert length(linkedin_drafts) == 2

      [first_twitter | _] = twitter_drafts
      assert first_twitter.content_type == "post"
      assert first_twitter.status == "draft"
      assert first_twitter.bundle_id == bundle.id
      assert first_twitter.image_url == featured_asset.storage_key
      assert first_twitter.generating_model =~ "anthropic:claude-sonnet-4-6-20250929"
      assert first_twitter.content =~ "Twitter variant"

      attached = ContentGeneration.list_assets_for_draft(first_twitter.id)
      assert Enum.map(attached, & &1.id) == [featured_asset.id]
    end

    test "parses fenced-JSON output from the LLM", %{bundle: bundle} do
      Req.Test.stub(@stub_key, fn conn ->
        fenced = """
        Here are your variants:

        ```json
        #{encoded_variants()}
        ```
        """

        Req.Test.json(conn, assistant_response(fenced))
      end)

      assert {:ok, drafts} = run_job(bundle, ["twitter", "linkedin"], 2)
      assert length(drafts) == 4
    end

    test "platforms asked for but missing from the LLM payload are skipped without crashing",
         %{bundle: bundle} do
      Req.Test.stub(@stub_key, fn conn ->
        Req.Test.json(
          conn,
          assistant_response(
            JSON.encode!(%{"platforms" => %{"twitter" => ["Tweet 1", "Tweet 2"]}})
          )
        )
      end)

      assert {:ok, drafts} = run_job(bundle, ["twitter", "linkedin"], 2)
      assert length(drafts) == 2
      assert Enum.all?(drafts, &(&1.platform == "twitter"))
    end
  end

  describe "downgrade + failure modes" do
    test "returns {:ok, :skipped} without creating drafts when Anthropic is not configured",
         %{bundle: bundle} do
      cfg =
        Application.get_env(:content_forge, @llm_key)[:anthropic] |> Keyword.put(:api_key, nil)

      Application.put_env(:content_forge, @llm_key, anthropic: cfg)

      test_pid = self()

      Req.Test.stub(@stub_key, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no HTTP expected when LLM is not configured"
      end)

      assert capture_log(fn ->
               assert {:ok, :skipped} = run_job(bundle, ["twitter"], 2)
             end) =~ "LLM unavailable"

      refute_received :unexpected_http
      assert [] = Repo.all(Draft)
    end

    test "malformed JSON cancels the job without creating any drafts", %{bundle: bundle} do
      Req.Test.stub(@stub_key, fn conn ->
        Req.Test.json(conn, assistant_response("<<< not json at all >>>"))
      end)

      log =
        capture_log(fn ->
          assert {:cancel, reason} = run_job(bundle, ["twitter"], 2)
          assert reason =~ "malformed"
        end)

      assert log =~ "AssetBundleDraftGenerator"
      assert [] = Repo.all(Draft)
    end

    test "transient HTTP error returns {:error, _} so Oban retries", %{bundle: bundle} do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{"error" => "service unavailable"})
      end)

      log =
        capture_log(fn ->
          assert {:error, {:transient, 503, _}} = run_job(bundle, ["twitter"], 2)
        end)

      assert log =~ "transient"
      assert [] = Repo.all(Draft)
    end

    test "permanent HTTP error cancels the job", %{bundle: bundle} do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => "bad request"})
      end)

      log =
        capture_log(fn ->
          assert {:cancel, reason} = run_job(bundle, ["twitter"], 2)
          assert reason =~ "HTTP 400"
        end)

      assert log =~ "permanent"
      assert [] = Repo.all(Draft)
    end
  end

  describe "bundle guards" do
    test "cancels when the bundle has no assets", %{product: product} do
      {:ok, empty} =
        ProductAssets.create_bundle(%{product_id: product.id, name: "Empty"})

      log =
        capture_log(fn ->
          assert {:cancel, reason} =
                   run_job_with_args(%{
                     "bundle_id" => empty.id,
                     "platforms" => ["twitter"],
                     "variants_per_platform" => 2
                   })

          assert reason =~ "no assets"
        end)

      assert log =~ "AssetBundleDraftGenerator"
      assert [] = Repo.all(Draft)
    end
  end

  describe "banner stickiness hardening" do
    test "broadcasts :bundle_generation_finished even if the LLM client raises",
         %{bundle: bundle} do
      :ok = ProductAssets.subscribe_bundles(bundle.product_id)

      Req.Test.stub(@stub_key, fn _conn ->
        raise "simulated transport crash"
      end)

      capture_log(fn ->
        try do
          run_job(bundle, ["twitter"], 2)
        rescue
          _ -> :ok
        catch
          _kind, _reason -> :ok
        end
      end)

      assert_receive {:bundle_generation_finished, bundle_id}, 500
      assert bundle_id == bundle.id
    end
  end
end
