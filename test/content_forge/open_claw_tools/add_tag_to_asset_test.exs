defmodule ContentForge.OpenClawTools.AddTagToAssetTest do
  @moduledoc """
  Phase 16.3c light-write tool: adds a single tag to a product's
  asset. Gated by `:submitter`; the asset lookup is scoped to
  the resolved product so a cross-product `asset_id` cannot
  mutate another product's row.
  """
  use ContentForge.DataCase, async: false

  alias ContentForge.OpenClawTools.AddTagToAsset
  alias ContentForge.ProductAssets
  alias ContentForge.Products
  alias ContentForge.Sms

  setup do
    {:ok, product} =
      Products.create_product(%{name: "Tagland", voice_profile: "warm"})

    {:ok, asset} =
      ProductAssets.create_asset(%{
        product_id: product.id,
        storage_key: "products/#{product.id}/assets/alpha",
        media_type: "image",
        filename: "alpha.jpg",
        mime_type: "image/jpeg",
        byte_size: 1024,
        uploaded_at: DateTime.utc_now()
      })

    %{product: product, asset: asset}
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
    test "happy path adds a single tag and returns the merged list",
         %{product: product, asset: asset} do
      ctx = sms_ctx("+15554440001", "submitter", product)

      assert {:ok, %{asset_id: id, tags: ["spring"]}} =
               AddTagToAsset.call(ctx, %{
                 "product" => product.id,
                 "asset_id" => asset.id,
                 "tag" => "spring"
               })

      assert id == asset.id
    end

    test "trims whitespace and lowercases the tag before persisting",
         %{product: product, asset: asset} do
      ctx = sms_ctx("+15554440002", "submitter", product)

      assert {:ok, %{tags: ["spring"]}} =
               AddTagToAsset.call(ctx, %{
                 "product" => product.id,
                 "asset_id" => asset.id,
                 "tag" => "  SPRING  "
               })
    end

    test "merging a duplicate tag is a no-op on the persisted set",
         %{product: product, asset: asset} do
      ctx = sms_ctx("+15554440003", "submitter", product)

      {:ok, _} =
        AddTagToAsset.call(ctx, %{
          "product" => product.id,
          "asset_id" => asset.id,
          "tag" => "summer"
        })

      assert {:ok, %{tags: ["summer"]}} =
               AddTagToAsset.call(ctx, %{
                 "product" => product.id,
                 "asset_id" => asset.id,
                 "tag" => "summer"
               })

      reloaded = ProductAssets.get_asset(asset.id)
      assert reloaded.tags == ["summer"]
    end

    test "unknown asset_id returns :not_found", %{product: product} do
      ctx = sms_ctx("+15554440004", "submitter", product)

      assert {:error, :not_found} =
               AddTagToAsset.call(ctx, %{
                 "product" => product.id,
                 "asset_id" => Ecto.UUID.generate(),
                 "tag" => "summer"
               })
    end

    test "asset belonging to a different product returns :not_found", %{product: product} do
      {:ok, other} =
        Products.create_product(%{name: "Outsider", voice_profile: "warm"})

      {:ok, other_asset} =
        ProductAssets.create_asset(%{
          product_id: other.id,
          storage_key: "products/#{other.id}/assets/outside",
          media_type: "image",
          filename: "outside.jpg",
          mime_type: "image/jpeg",
          byte_size: 1024,
          uploaded_at: DateTime.utc_now()
        })

      ctx = sms_ctx("+15554440005", "submitter", product)

      assert {:error, :not_found} =
               AddTagToAsset.call(ctx, %{
                 "product" => product.id,
                 "asset_id" => other_asset.id,
                 "tag" => "summer"
               })
    end

    test "viewer role returns :forbidden without mutating the row",
         %{product: product, asset: asset} do
      ctx = sms_ctx("+15554440006", "viewer", product)

      assert {:error, :forbidden} =
               AddTagToAsset.call(ctx, %{
                 "product" => product.id,
                 "asset_id" => asset.id,
                 "tag" => "winter"
               })

      reloaded = ProductAssets.get_asset(asset.id)
      assert reloaded.tags == []
    end

    test "empty tag returns :invalid_tag", %{product: product, asset: asset} do
      ctx = sms_ctx("+15554440007", "submitter", product)

      assert {:error, :invalid_tag} =
               AddTagToAsset.call(ctx, %{
                 "product" => product.id,
                 "asset_id" => asset.id,
                 "tag" => "   "
               })

      assert {:error, :invalid_tag} =
               AddTagToAsset.call(ctx, %{
                 "product" => product.id,
                 "asset_id" => asset.id
               })
    end

    test "tag over 40 chars returns :invalid_tag", %{product: product, asset: asset} do
      ctx = sms_ctx("+15554440008", "submitter", product)

      long = String.duplicate("x", 41)

      assert {:error, :invalid_tag} =
               AddTagToAsset.call(ctx, %{
                 "product" => product.id,
                 "asset_id" => asset.id,
                 "tag" => long
               })
    end

    test "malformed asset_id returns :not_found", %{product: product} do
      ctx = sms_ctx("+15554440009", "submitter", product)

      assert {:error, :not_found} =
               AddTagToAsset.call(ctx, %{
                 "product" => product.id,
                 "asset_id" => "not-a-uuid",
                 "tag" => "spring"
               })
    end
  end
end
