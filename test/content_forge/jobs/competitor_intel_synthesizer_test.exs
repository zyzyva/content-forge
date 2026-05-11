defmodule ContentForge.Jobs.CompetitorIntelSynthesizerTest do
  use ContentForge.DataCase, async: false

  use Oban.Testing, repo: ContentForge.Repo

  import ExUnit.CaptureLog

  alias ContentForge.Jobs.CompetitorIntelSynthesizer
  alias ContentForge.Products

  defmodule StubModel do
    @moduledoc false
    def summarize(posts) do
      {:ok,
       %{
         summary: "Analyzed #{length(posts)} posts",
         trending_topics: ["topic-a", "topic-b"],
         winning_formats: ["Q&A"],
         effective_hooks: ["Announcement hook"]
       }}
    end
  end

  defmodule ErrorModel do
    @moduledoc false
    def summarize(_posts), do: {:error, :model_timeout}
  end

  setup do
    original = Application.get_env(:content_forge, :intel_model)

    on_exit(fn ->
      restore(:intel_model, original)
    end)

    {:ok, product} =
      Products.create_product(%{name: "Test Product", voice_profile: "professional"})

    %{product: product}
  end

  defp restore(key, nil), do: Application.delete_env(:content_forge, key)
  defp restore(key, value), do: Application.put_env(:content_forge, key, value)

  describe "perform/1 gating" do
    test "discards when intel_model is not configured", %{product: product} do
      Application.delete_env(:content_forge, :intel_model)

      assert {:discard, :intel_model_not_configured} =
               perform_job(CompetitorIntelSynthesizer, %{"product_id" => product.id})
    end
  end

  describe "perform/1 with model wired" do
    setup do
      Application.put_env(:content_forge, :intel_model, StubModel)
      :ok
    end

    test "returns :ok and stores nothing when no top posts exist", %{product: product} do
      assert :ok = perform_job(CompetitorIntelSynthesizer, %{"product_id" => product.id})
      assert Products.list_competitor_intel_for_product(product.id) == []
    end

    test "stores intel when top posts exist", %{product: product} do
      {:ok, account} =
        Products.create_competitor_account(%{
          product_id: product.id,
          platform: "twitter",
          handle: "acme",
          url: "https://twitter.com/acme",
          active: true
        })

      {:ok, _post} =
        Products.create_competitor_post(%{
          competitor_account_id: account.id,
          post_id: "p1",
          content: "a post",
          post_url: "https://example.com/1",
          likes_count: 10,
          comments_count: 1,
          shares_count: 1,
          engagement_score: 2.5,
          posted_at: DateTime.utc_now(),
          raw_data: %{}
        })

      assert :ok = perform_job(CompetitorIntelSynthesizer, %{"product_id" => product.id})

      intel = Products.list_competitor_intel_for_product(product.id)
      assert length(intel) == 1
      [entry] = intel
      assert entry.summary =~ "Analyzed"
      assert entry.trending_topics == ["topic-a", "topic-b"]
      assert entry.effective_hooks == ["Announcement hook"]
      assert entry.source_count == 1
    end

    test "returns error when product not found" do
      log =
        capture_log(fn ->
          assert {:error, :not_found} =
                   perform_job(CompetitorIntelSynthesizer, %{
                     "product_id" => Ecto.UUID.generate()
                   })
        end)

      assert log =~ "Competitor intel synthesis failed"
    end
  end

  describe "perform/1 when model adapter errors" do
    setup do
      Application.put_env(:content_forge, :intel_model, ErrorModel)
      :ok
    end

    test "returns the model error", %{product: product} do
      {:ok, account} =
        Products.create_competitor_account(%{
          product_id: product.id,
          platform: "twitter",
          handle: "acme",
          url: "https://twitter.com/acme",
          active: true
        })

      {:ok, _post} =
        Products.create_competitor_post(%{
          competitor_account_id: account.id,
          post_id: "p1",
          content: "a post",
          post_url: "https://example.com/1",
          likes_count: 10,
          comments_count: 1,
          shares_count: 1,
          engagement_score: 2.5,
          posted_at: DateTime.utc_now(),
          raw_data: %{}
        })

      log =
        capture_log(fn ->
          assert {:error, :model_timeout} =
                   perform_job(CompetitorIntelSynthesizer, %{"product_id" => product.id})
        end)

      assert log =~ "Competitor intel synthesis failed"
      assert Products.list_competitor_intel_for_product(product.id) == []
    end
  end

  describe "Phase 17.4 paths" do
    defmodule WithKeyModel do
      @moduledoc false
      def summarize(posts) do
        # Returns audience_signals so the synthesizer can persist them.
        {:ok,
         %{
           summary: "with-key path",
           trending_topics: ["topic"],
           winning_formats: ["format"],
           effective_hooks: ["hook"],
           audience_signals: ["signal-a", "signal-b"]
         }}
        |> tap(fn _ -> send(self(), {:summarized, length(posts)}) end)
      end
    end

    defmodule NotConfiguredModel do
      @moduledoc false
      def summarize(_posts), do: {:error, :not_configured}
    end

    defp seed_competitor_post(product) do
      {:ok, account} =
        Products.create_competitor_account(%{
          product_id: product.id,
          platform: "twitter",
          handle: "acme",
          url: "https://x.com/acme",
          active: true
        })

      {:ok, post} =
        Products.create_competitor_post(%{
          competitor_account_id: account.id,
          post_id: "p1",
          content: "a post",
          post_url: "https://example.com/1",
          likes_count: 10,
          comments_count: 1,
          shares_count: 1,
          engagement_score: 2.5,
          posted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      post
    end

    test "with-key path persists audience_signals + window", %{product: product} do
      Application.put_env(:content_forge, :intel_model, WithKeyModel)
      _post = seed_competitor_post(product)

      assert :ok =
               perform_job(CompetitorIntelSynthesizer, %{
                 "product_id" => product.id,
                 "window" => "week"
               })

      [intel] = Products.list_competitor_intel_for_product(product.id)
      assert intel.summary == "with-key path"
      assert intel.audience_signals == ["signal-a", "signal-b"]
      assert intel.window == "week"
      assert intel.source_count == 1
    end

    test "with-key path defaults window to all when arg omitted", %{product: product} do
      Application.put_env(:content_forge, :intel_model, WithKeyModel)
      _post = seed_competitor_post(product)

      assert :ok = perform_job(CompetitorIntelSynthesizer, %{"product_id" => product.id})

      [intel] = Products.list_competitor_intel_for_product(product.id)
      assert intel.window == "all"
    end

    test "with-key path resolves matching pending rows on success", %{product: product} do
      Application.put_env(:content_forge, :intel_model, WithKeyModel)
      _post = seed_competitor_post(product)

      {:ok, _pending} =
        Products.create_pending_intel_synthesis(%{
          product_id: product.id,
          window: "week",
          source_post_ids: []
        })

      # Pending for a different window should NOT be resolved.
      {:ok, _other} =
        Products.create_pending_intel_synthesis(%{
          product_id: product.id,
          window: "month",
          source_post_ids: []
        })

      assert :ok =
               perform_job(CompetitorIntelSynthesizer, %{
                 "product_id" => product.id,
                 "window" => "week"
               })

      pending = Products.list_pending_intel_syntheses_for_product(product.id)
      assert length(pending) == 1
      assert hd(pending).window == "month"
    end

    test "without-key (:not_configured) creates a pending row + :discard",
         %{product: product} do
      Application.put_env(:content_forge, :intel_model, NotConfiguredModel)
      post = seed_competitor_post(product)

      assert {:discard, :not_configured} =
               perform_job(CompetitorIntelSynthesizer, %{
                 "product_id" => product.id,
                 "window" => "week"
               })

      [pending] = Products.list_pending_intel_syntheses_for_product(product.id)
      assert pending.window == "week"
      assert pending.source_post_ids == [post.id]
      assert pending.note =~ "ANTHROPIC_API_KEY"
      assert Products.list_competitor_intel_for_product(product.id) == []
    end

    test "no-adapter-wired boot also routes to pending_manual", %{product: product} do
      Application.delete_env(:content_forge, :intel_model)

      assert {:discard, :intel_model_not_configured} =
               perform_job(CompetitorIntelSynthesizer, %{
                 "product_id" => product.id,
                 "window" => "all"
               })

      [pending] = Products.list_pending_intel_syntheses_for_product(product.id)
      assert pending.window == "all"
      assert pending.source_post_ids == []
      assert pending.note =~ "intel_model"
    end
  end
end
