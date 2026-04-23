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
end
