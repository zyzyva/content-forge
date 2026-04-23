defmodule ContentForge.ContentGeneration.DraftAssetTest do
  use ContentForge.DataCase, async: true

  alias ContentForge.ContentGeneration
  alias ContentForge.ContentGeneration.Draft
  alias ContentForge.ContentGeneration.DraftAsset
  alias ContentForge.ProductAssets
  alias ContentForge.ProductAssets.ProductAsset
  alias ContentForge.Products

  defp create_product!(name \\ "Test Product") do
    {:ok, product} = Products.create_product(%{name: name, voice_profile: "professional"})
    product
  end

  defp create_draft!(product, attrs \\ %{}) do
    defaults = %{
      product_id: product.id,
      content: "Test content",
      platform: "twitter",
      content_type: "post",
      generating_model: "claude"
    }

    {:ok, draft} = ContentGeneration.create_draft(Map.merge(defaults, attrs))
    draft
  end

  defp create_asset!(product, overrides \\ %{}) do
    defaults = %{
      product_id: product.id,
      storage_key: "products/#{product.id}/assets/#{Ecto.UUID.generate()}/hero.jpg",
      media_type: "image",
      filename: "hero.jpg",
      mime_type: "image/jpeg",
      byte_size: 1024,
      uploaded_at: DateTime.utc_now(),
      tags: []
    }

    {:ok, asset} = ProductAssets.create_asset(Map.merge(defaults, overrides))
    asset
  end

  describe "attach_asset/3" do
    test "attaches an asset with the default featured role" do
      product = create_product!()
      draft = create_draft!(product)
      asset = create_asset!(product)

      assert {:ok, %DraftAsset{} = row} = ContentGeneration.attach_asset(draft, asset)
      assert row.draft_id == draft.id
      assert row.asset_id == asset.id
      assert row.role == "featured"
    end

    test "accepts an explicit role=gallery" do
      product = create_product!()
      draft = create_draft!(product)
      asset = create_asset!(product)

      assert {:ok, %DraftAsset{role: "gallery"}} =
               ContentGeneration.attach_asset(draft, asset, role: "gallery")
    end

    test "rejects an unknown role" do
      product = create_product!()
      draft = create_draft!(product)
      asset = create_asset!(product)

      assert {:error, changeset} =
               ContentGeneration.attach_asset(draft, asset, role: "spotlight")

      assert "is invalid" in errors_on(changeset).role
    end

    test "duplicate attach is a no-op and returns the existing row" do
      product = create_product!()
      draft = create_draft!(product)
      asset = create_asset!(product)

      {:ok, first} = ContentGeneration.attach_asset(draft, asset)
      assert {:ok, second} = ContentGeneration.attach_asset(draft, asset)
      assert second.id == first.id

      assert Repo.aggregate(
               from(da in DraftAsset,
                 where: da.draft_id == ^draft.id and da.asset_id == ^asset.id
               ),
               :count
             ) == 1
    end

    test "accepts struct arguments or ids" do
      product = create_product!()
      draft = create_draft!(product)
      asset = create_asset!(product)

      assert {:ok, %DraftAsset{}} =
               ContentGeneration.attach_asset(draft.id, asset.id)
    end
  end

  describe "detach_asset/2" do
    test "removes the join row if present" do
      product = create_product!()
      draft = create_draft!(product)
      asset = create_asset!(product)
      {:ok, _} = ContentGeneration.attach_asset(draft, asset)

      assert :ok = ContentGeneration.detach_asset(draft, asset)

      assert [] =
               Repo.all(
                 from(da in DraftAsset,
                   where: da.draft_id == ^draft.id and da.asset_id == ^asset.id
                 )
               )
    end

    test "is a no-op if the asset is not attached" do
      product = create_product!()
      draft = create_draft!(product)
      asset = create_asset!(product)

      assert :ok = ContentGeneration.detach_asset(draft, asset)
    end
  end

  describe "list_assets_for_draft/1" do
    test "returns attached assets in insertion order" do
      product = create_product!()
      draft = create_draft!(product)
      a = create_asset!(product, %{filename: "a.jpg"})
      b = create_asset!(product, %{filename: "b.jpg"})
      c = create_asset!(product, %{filename: "c.jpg"})

      {:ok, _} = ContentGeneration.attach_asset(draft, a)
      {:ok, _} = ContentGeneration.attach_asset(draft, b, role: "gallery")
      {:ok, _} = ContentGeneration.attach_asset(draft, c, role: "gallery")

      assets = ContentGeneration.list_assets_for_draft(draft.id)
      assert Enum.map(assets, & &1.id) == [a.id, b.id, c.id]
      assert Enum.all?(assets, &match?(%ProductAsset{}, &1))
    end

    test "returns [] when no assets are attached" do
      product = create_product!()
      draft = create_draft!(product)

      assert ContentGeneration.list_assets_for_draft(draft.id) == []
    end
  end

  describe "has_many :assets through :draft_assets" do
    test "preloads attached assets on a draft" do
      product = create_product!()
      draft = create_draft!(product)
      asset = create_asset!(product)
      {:ok, _} = ContentGeneration.attach_asset(draft, asset)

      reloaded = Repo.preload(Repo.get!(Draft, draft.id), :assets)
      assert Enum.map(reloaded.assets, & &1.id) == [asset.id]
    end
  end

  describe "cascade delete" do
    test "deleting a draft removes its draft_assets rows" do
      product = create_product!()
      draft = create_draft!(product)
      asset = create_asset!(product)
      {:ok, _} = ContentGeneration.attach_asset(draft, asset)

      Repo.delete!(draft)

      assert [] =
               Repo.all(from(da in DraftAsset, where: da.draft_id == ^draft.id))

      refute Repo.get(Draft, draft.id)
      assert %ProductAsset{} = ProductAssets.get_asset!(asset.id)
    end

    test "deleting an asset removes its draft_assets rows" do
      product = create_product!()
      draft = create_draft!(product)
      asset = create_asset!(product)
      {:ok, _} = ContentGeneration.attach_asset(draft, asset)

      Repo.delete!(asset)

      assert [] =
               Repo.all(from(da in DraftAsset, where: da.asset_id == ^asset.id))

      refute Repo.get(ProductAsset, asset.id)
      assert %Draft{} = ContentGeneration.get_draft!(draft.id)
    end
  end
end
