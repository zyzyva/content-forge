defmodule ContentForge.OpenClawTools.GenerateDraftsFromBundleTest do
  @moduledoc """
  Phase 16.4d: heavy-write tool that surfaces estimated cost +
  remaining budget on turn one and enqueues
  `AssetBundleDraftGenerator` on turn two. Budget is
  transparency-only: over-budget requests still enqueue, with a
  `warning` string in the preview the agent is expected to read
  verbatim to the user.
  """
  use ContentForge.DataCase, async: false
  use Oban.Testing, repo: ContentForge.Repo

  alias ContentForge.Jobs.AssetBundleDraftGenerator
  alias ContentForge.OpenClawTools.GenerateDraftsFromBundle
  alias ContentForge.OpenClawTools.PendingConfirmation
  alias ContentForge.Operators
  alias ContentForge.ProductAssets
  alias ContentForge.Products
  alias ContentForge.Repo

  setup do
    original = Application.get_env(:content_forge, :generation_budget)

    Application.put_env(:content_forge, :generation_budget,
      monthly_cents: 10_000,
      cost_per_variant_cents: 5,
      default_platforms: ["twitter", "linkedin"],
      default_variants_per_platform: 3
    )

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:content_forge, :generation_budget)
      else
        Application.put_env(:content_forge, :generation_budget, original)
      end
    end)

    {:ok, product} =
      Products.create_product(%{name: "Bundleville", voice_profile: "warm"})

    {:ok, bundle} =
      ProductAssets.create_bundle(%{
        product_id: product.id,
        name: "Campaign bundle",
        context: "autumn promo"
      })

    # Attach a couple of assets to the bundle so the cost math > 0.
    for i <- 1..3 do
      {:ok, asset} =
        ProductAssets.create_asset(%{
          product_id: product.id,
          storage_key: "products/#{product.id}/assets/b#{i}",
          media_type: "image",
          filename: "b#{i}.jpg",
          mime_type: "image/jpeg",
          byte_size: 1024,
          uploaded_at: DateTime.utc_now()
        })

      {:ok, _} =
        ProductAssets.add_asset_to_bundle(bundle, asset, position: i)
    end

    %{product: product, bundle: bundle}
  end

  defp cli_owner_ctx(identity, product, session_id) do
    {:ok, _} =
      Operators.create_identity(%{
        product_id: product.id,
        identity: identity,
        role: "owner"
      })

    %{channel: "cli", sender_identity: identity, session_id: session_id}
  end

  describe "authorization" do
    test "submitter = :forbidden with no pending row + no job",
         %{product: product, bundle: bundle} do
      {:ok, _} =
        Operators.create_identity(%{
          product_id: product.id,
          identity: "cli:submitter",
          role: "submitter"
        })

      ctx = %{channel: "cli", sender_identity: "cli:submitter", session_id: "sess-sub"}

      assert {:error, :forbidden} =
               GenerateDraftsFromBundle.call(ctx, %{
                 "product" => product.id,
                 "bundle_id" => bundle.id
               })

      assert Repo.aggregate(PendingConfirmation, :count, :id) == 0
      refute_enqueued(worker: AssetBundleDraftGenerator)
    end
  end

  describe "bundle scoping" do
    test "cross-product bundle = :not_found", %{product: product} do
      {:ok, other} =
        Products.create_product(%{name: "Otherbundle", voice_profile: "warm"})

      {:ok, other_bundle} =
        ProductAssets.create_bundle(%{product_id: other.id, name: "foreign"})

      ctx = cli_owner_ctx("cli:cross", product, "sess-cross")

      assert {:error, :not_found} =
               GenerateDraftsFromBundle.call(ctx, %{
                 "product" => product.id,
                 "bundle_id" => other_bundle.id
               })
    end

    test "unknown bundle = :not_found", %{product: product} do
      ctx = cli_owner_ctx("cli:no-bundle", product, "sess-nb")

      assert {:error, :not_found} =
               GenerateDraftsFromBundle.call(ctx, %{
                 "product" => product.id,
                 "bundle_id" => Ecto.UUID.generate()
               })
    end

    test "malformed bundle_id = :not_found", %{product: product} do
      ctx = cli_owner_ctx("cli:bad", product, "sess-bad")

      assert {:error, :not_found} =
               GenerateDraftsFromBundle.call(ctx, %{
                 "product" => product.id,
                 "bundle_id" => "not-a-uuid"
               })
    end
  end

  describe "first turn" do
    test "preview carries asset_count + estimated_cost + remaining_budget + would_exceed_budget",
         %{product: product, bundle: bundle} do
      ctx = cli_owner_ctx("cli:first", product, "sess-first")

      assert {:ok, :confirmation_required, envelope} =
               GenerateDraftsFromBundle.call(ctx, %{
                 "product" => product.id,
                 "bundle_id" => bundle.id
               })

      preview = envelope.preview
      assert preview.bundle_id == bundle.id
      assert preview.asset_count == 3

      # 3 assets * 2 platforms * 3 variants * 5 cents = 90
      assert preview.estimated_cost_cents == 90
      assert preview.remaining_budget_cents == 10_000
      assert preview.would_exceed_budget == false
      assert is_binary(preview.summary)
      assert is_map_key(preview, :warning) == false or is_nil(preview.warning)
    end

    test "over-budget estimate sets would_exceed_budget + warning string",
         %{product: product, bundle: bundle} do
      Application.put_env(:content_forge, :generation_budget,
        monthly_cents: 10,
        cost_per_variant_cents: 5,
        default_platforms: ["twitter", "linkedin"],
        default_variants_per_platform: 3
      )

      ctx = cli_owner_ctx("cli:over", product, "sess-over")

      assert {:ok, :confirmation_required, envelope} =
               GenerateDraftsFromBundle.call(ctx, %{
                 "product" => product.id,
                 "bundle_id" => bundle.id
               })

      preview = envelope.preview
      assert preview.would_exceed_budget == true
      assert is_binary(preview.warning)
      assert preview.warning =~ "budget"
    end

    test "idempotent: same bundle returns same echo phrase + single pending row",
         %{product: product, bundle: bundle} do
      ctx = cli_owner_ctx("cli:idemp", product, "sess-gen-idemp")
      params = %{"product" => product.id, "bundle_id" => bundle.id}

      assert {:ok, :confirmation_required, first} =
               GenerateDraftsFromBundle.call(ctx, params)

      assert {:ok, :confirmation_required, second} =
               GenerateDraftsFromBundle.call(ctx, params)

      assert first.echo_phrase == second.echo_phrase
      assert Repo.aggregate(PendingConfirmation, :count, :id) == 1
    end
  end

  describe "second turn" do
    test "correct confirm enqueues the Oban job",
         %{product: product, bundle: bundle} do
      ctx = cli_owner_ctx("cli:exec", product, "sess-exec")
      params = %{"product" => product.id, "bundle_id" => bundle.id}

      {:ok, :confirmation_required, envelope} =
        GenerateDraftsFromBundle.call(ctx, params)

      confirm_params = Map.put(params, "confirm", envelope.echo_phrase)

      assert {:ok, result} = GenerateDraftsFromBundle.call(ctx, confirm_params)
      assert result.enqueued == true
      assert result.bundle_id == bundle.id
      assert result.estimated_cost_cents == 90
      assert result.remaining_budget_cents == 10_000
      assert is_map(result.job_args)

      assert_enqueued(
        worker: AssetBundleDraftGenerator,
        args: %{"bundle_id" => bundle.id}
      )
    end

    test "wrong echo = :confirmation_not_found with no enqueue",
         %{product: product, bundle: bundle} do
      ctx = cli_owner_ctx("cli:wrong", product, "sess-wrong")

      assert {:error, :confirmation_not_found} =
               GenerateDraftsFromBundle.call(ctx, %{
                 "product" => product.id,
                 "bundle_id" => bundle.id,
                 "confirm" => "crimson-otter-nowhere"
               })

      refute_enqueued(worker: AssetBundleDraftGenerator)
    end

    test "over-budget still enqueues on confirm (warning, not block)",
         %{product: product, bundle: bundle} do
      Application.put_env(:content_forge, :generation_budget,
        monthly_cents: 10,
        cost_per_variant_cents: 5,
        default_platforms: ["twitter", "linkedin"],
        default_variants_per_platform: 3
      )

      ctx = cli_owner_ctx("cli:over-exec", product, "sess-over-exec")
      params = %{"product" => product.id, "bundle_id" => bundle.id}

      {:ok, :confirmation_required, envelope} =
        GenerateDraftsFromBundle.call(ctx, params)

      confirm_params = Map.put(params, "confirm", envelope.echo_phrase)

      assert {:ok, result} = GenerateDraftsFromBundle.call(ctx, confirm_params)
      assert result.enqueued == true

      assert_enqueued(worker: AssetBundleDraftGenerator)
    end
  end
end
