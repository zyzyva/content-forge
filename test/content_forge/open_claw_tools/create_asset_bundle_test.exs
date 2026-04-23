defmodule ContentForge.OpenClawTools.CreateAssetBundleTest do
  @moduledoc """
  Phase 16.3c light-write tool: creates a named `AssetBundle`
  for the resolved product. Gated by `:submitter`; param
  validation covers the name (1..120 chars, trimmed) and
  optional context.
  """
  use ContentForge.DataCase, async: false

  alias ContentForge.OpenClawTools.CreateAssetBundle
  alias ContentForge.ProductAssets
  alias ContentForge.Products
  alias ContentForge.Sms

  setup do
    {:ok, product} =
      Products.create_product(%{name: "Bundleland", voice_profile: "warm"})

    %{product: product}
  end

  defp sms_ctx(phone, role, product) do
    {:ok, _} =
      Sms.create_phone(%{
        product_id: product.id,
        phone_number: phone,
        role: role,
        active: true
      })

    %{channel: "sms", sender_identity: phone, product: product}
  end

  describe "call/2" do
    test "happy path creates a bundle and returns its metadata", %{product: product} do
      ctx = sms_ctx("+15553330001", "submitter", product)

      assert {:ok, result} =
               CreateAssetBundle.call(ctx, %{
                 "product" => product.id,
                 "name" => "Winter promo kitchen remodel",
                 "context" => "Johnson family, 3 weeks, quartz counters"
               })

      assert result.product_id == product.id
      assert result.product_name == "Bundleland"
      assert result.name == "Winter promo kitchen remodel"
      assert result.status == "active"
      assert is_binary(result.created_at)
      assert is_binary(result.bundle_id)

      [persisted] = ProductAssets.list_bundles(product.id)
      assert persisted.id == result.bundle_id
    end

    test "trims whitespace on name", %{product: product} do
      ctx = sms_ctx("+15553330002", "submitter", product)

      assert {:ok, %{name: "Trimmed"}} =
               CreateAssetBundle.call(ctx, %{
                 "product" => product.id,
                 "name" => "   Trimmed   "
               })
    end

    test "viewer role returns :forbidden without inserting", %{product: product} do
      ctx = sms_ctx("+15553330003", "viewer", product)

      assert {:error, :forbidden} =
               CreateAssetBundle.call(ctx, %{
                 "product" => product.id,
                 "name" => "Nope"
               })

      assert ProductAssets.list_bundles(product.id) == []
    end

    test "empty name returns :invalid_name", %{product: product} do
      ctx = sms_ctx("+15553330004", "submitter", product)

      assert {:error, :invalid_name} =
               CreateAssetBundle.call(ctx, %{"product" => product.id, "name" => "   "})

      assert {:error, :invalid_name} =
               CreateAssetBundle.call(ctx, %{"product" => product.id, "name" => ""})

      assert {:error, :invalid_name} =
               CreateAssetBundle.call(ctx, %{"product" => product.id})
    end

    test "name over 120 chars returns :invalid_name", %{product: product} do
      ctx = sms_ctx("+15553330005", "submitter", product)

      long = String.duplicate("x", 121)

      assert {:error, :invalid_name} =
               CreateAssetBundle.call(ctx, %{"product" => product.id, "name" => long})
    end

    test "ambiguous product match returns :ambiguous_product before auth",
         %{product: _product} do
      {:ok, _} = Products.create_product(%{name: "Shared Name Alpha", voice_profile: "warm"})
      {:ok, _} = Products.create_product(%{name: "Shared Name Beta", voice_profile: "warm"})

      ctx = %{channel: "cli", sender_identity: "cli:unused"}

      assert {:error, :ambiguous_product} =
               CreateAssetBundle.call(ctx, %{"product" => "shared name", "name" => "bundle"})
    end
  end
end
