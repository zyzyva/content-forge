defmodule ContentForge.ProductAssets.AssetBundleTest do
  use ContentForge.DataCase, async: false

  alias ContentForge.ProductAssets
  alias ContentForge.ProductAssets.AssetBundle
  alias ContentForge.ProductAssets.BundleAsset
  alias ContentForge.Products

  defp create_product!(name \\ "Test Product") do
    {:ok, product} = Products.create_product(%{name: name, voice_profile: "professional"})
    product
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

  describe "create_bundle/1" do
    test "creates an active bundle and broadcasts :bundle_created" do
      product = create_product!()
      :ok = ProductAssets.subscribe_bundles(product.id)

      assert {:ok, %AssetBundle{} = bundle} =
               ProductAssets.create_bundle(%{
                 product_id: product.id,
                 name: "Johnson kitchen remodel",
                 context: "Quartz counters, custom cabinets, 3 weeks"
               })

      assert bundle.status == "active"
      assert_receive {:bundle_created, %AssetBundle{id: id}} when id == bundle.id
    end

    test "rejects missing name" do
      product = create_product!()

      assert {:error, changeset} = ProductAssets.create_bundle(%{product_id: product.id})
      assert "can't be blank" in errors_on(changeset).name
    end

    test "rejects name longer than 120 chars" do
      product = create_product!()
      name = String.duplicate("a", 121)

      assert {:error, changeset} =
               ProductAssets.create_bundle(%{product_id: product.id, name: name})

      assert Enum.any?(errors_on(changeset).name, &String.contains?(&1, "120"))
    end
  end

  describe "list_bundles/2 + status filters" do
    test "lists active bundles by default; soft-deleted and archived are hidden" do
      product = create_product!()

      {:ok, active} =
        ProductAssets.create_bundle(%{product_id: product.id, name: "Active"})

      {:ok, archived} =
        ProductAssets.create_bundle(%{product_id: product.id, name: "Archived"})

      {:ok, _} = ProductAssets.archive_bundle(archived)

      {:ok, deleted} =
        ProductAssets.create_bundle(%{product_id: product.id, name: "Deleted"})

      {:ok, _} = ProductAssets.soft_delete_bundle(deleted)

      assert [%AssetBundle{id: id}] = ProductAssets.list_bundles(product.id)
      assert id == active.id

      all_ids =
        ProductAssets.list_bundles(product.id, status: ~w(active archived deleted))
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert all_ids == Enum.sort([active.id, archived.id, deleted.id])
    end
  end

  describe "update_bundle/2 + archive_bundle/1 + soft_delete_bundle/1" do
    test "update_bundle applies changes and broadcasts :bundle_updated" do
      product = create_product!()
      {:ok, bundle} = ProductAssets.create_bundle(%{product_id: product.id, name: "Original"})
      :ok = ProductAssets.subscribe_bundles(product.id)

      assert {:ok, updated} =
               ProductAssets.update_bundle(bundle, %{
                 name: "Renamed",
                 context: "More detail"
               })

      assert updated.name == "Renamed"
      assert updated.context == "More detail"
      assert_receive {:bundle_updated, %AssetBundle{id: id}} when id == bundle.id
    end

    test "archive_bundle flips status and broadcasts :bundle_archived" do
      product = create_product!()
      {:ok, bundle} = ProductAssets.create_bundle(%{product_id: product.id, name: "N"})
      :ok = ProductAssets.subscribe_bundles(product.id)

      assert {:ok, updated} = ProductAssets.archive_bundle(bundle)
      assert updated.status == "archived"
      assert_receive {:bundle_archived, %AssetBundle{id: id}} when id == bundle.id
    end

    test "soft_delete_bundle flips status and broadcasts :bundle_deleted" do
      product = create_product!()
      {:ok, bundle} = ProductAssets.create_bundle(%{product_id: product.id, name: "N"})
      :ok = ProductAssets.subscribe_bundles(product.id)

      assert {:ok, updated} = ProductAssets.soft_delete_bundle(bundle)
      assert updated.status == "deleted"
      assert_receive {:bundle_deleted, %AssetBundle{id: id}} when id == bundle.id
    end
  end

  describe "add_asset_to_bundle/3" do
    test "adds a membership row with auto-increment position" do
      product = create_product!()
      {:ok, bundle} = ProductAssets.create_bundle(%{product_id: product.id, name: "B"})
      asset_a = create_asset!(product)
      asset_b = create_asset!(product)

      assert {:ok, %BundleAsset{} = row_a} =
               ProductAssets.add_asset_to_bundle(bundle, asset_a)

      assert row_a.position == 0

      assert {:ok, %BundleAsset{position: 1}} =
               ProductAssets.add_asset_to_bundle(bundle, asset_b)
    end

    test "duplicate add is a no-op and returns the existing row" do
      product = create_product!()
      {:ok, bundle} = ProductAssets.create_bundle(%{product_id: product.id, name: "B"})
      asset = create_asset!(product)

      {:ok, first} = ProductAssets.add_asset_to_bundle(bundle, asset)
      assert {:ok, second} = ProductAssets.add_asset_to_bundle(bundle, asset)
      assert second.id == first.id

      bundle = ProductAssets.get_bundle!(bundle.id)
      assert length(bundle.bundle_assets) == 1
    end

    test "broadcasts :bundle_membership_changed on successful add" do
      product = create_product!()
      {:ok, bundle} = ProductAssets.create_bundle(%{product_id: product.id, name: "B"})
      asset = create_asset!(product)
      :ok = ProductAssets.subscribe_bundles(product.id)

      assert {:ok, _} = ProductAssets.add_asset_to_bundle(bundle, asset)
      assert_receive {:bundle_membership_changed, %AssetBundle{id: id}} when id == bundle.id
    end
  end

  describe "remove_asset_from_bundle/2" do
    test "removes a membership row and broadcasts" do
      product = create_product!()
      {:ok, bundle} = ProductAssets.create_bundle(%{product_id: product.id, name: "B"})
      asset = create_asset!(product)
      {:ok, _} = ProductAssets.add_asset_to_bundle(bundle, asset)
      :ok = ProductAssets.subscribe_bundles(product.id)

      assert :ok = ProductAssets.remove_asset_from_bundle(bundle, asset)
      assert ProductAssets.get_bundle!(bundle.id).bundle_assets == []
      assert_receive {:bundle_membership_changed, %AssetBundle{id: id}} when id == bundle.id
    end

    test "is a no-op when the asset is not a member" do
      product = create_product!()
      {:ok, bundle} = ProductAssets.create_bundle(%{product_id: product.id, name: "B"})
      asset = create_asset!(product)

      assert :ok = ProductAssets.remove_asset_from_bundle(bundle, asset)
    end
  end

  describe "reorder_bundle_assets/2" do
    test "applies the requested ordering and ignores non-member ids" do
      product = create_product!()
      {:ok, bundle} = ProductAssets.create_bundle(%{product_id: product.id, name: "B"})
      a = create_asset!(product)
      b = create_asset!(product)
      c = create_asset!(product)

      {:ok, _} = ProductAssets.add_asset_to_bundle(bundle, a)
      {:ok, _} = ProductAssets.add_asset_to_bundle(bundle, b)
      {:ok, _} = ProductAssets.add_asset_to_bundle(bundle, c)

      assert {:ok, _} =
               ProductAssets.reorder_bundle_assets(bundle, [
                 c.id,
                 a.id,
                 Ecto.UUID.generate(),
                 b.id
               ])

      reloaded = ProductAssets.get_bundle!(bundle.id)
      ordered_ids = Enum.map(reloaded.bundle_assets, & &1.asset_id)
      assert ordered_ids == [c.id, a.id, b.id]
    end
  end

  describe "cascade delete" do
    test "deleting a product removes its bundles and their join rows" do
      product = create_product!("Doomed")
      {:ok, bundle} = ProductAssets.create_bundle(%{product_id: product.id, name: "B"})
      asset = create_asset!(product)
      {:ok, _} = ProductAssets.add_asset_to_bundle(bundle, asset)

      Repo.delete!(product)

      refute Repo.get(AssetBundle, bundle.id)

      remaining =
        from(ba in BundleAsset, where: ba.bundle_id == ^bundle.id) |> Repo.all()

      assert remaining == []
    end

    test "deleting a bundle removes its join rows but leaves the assets" do
      product = create_product!()
      {:ok, bundle} = ProductAssets.create_bundle(%{product_id: product.id, name: "B"})
      asset = create_asset!(product)
      {:ok, _} = ProductAssets.add_asset_to_bundle(bundle, asset)

      Repo.delete!(bundle)

      refute Repo.get(BundleAsset, bundle.id)

      assert %{status: _} = ProductAssets.get_asset!(asset.id)
    end
  end
end
