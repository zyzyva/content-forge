defmodule ContentForge.ProductAssetsTest do
  use ContentForge.DataCase, async: false

  alias ContentForge.ProductAssets
  alias ContentForge.ProductAssets.ProductAsset
  alias ContentForge.Products

  defp create_product!(attrs \\ %{}) do
    defaults = %{name: "Test Product", voice_profile: "professional"}
    {:ok, product} = Products.create_product(Map.merge(defaults, attrs))
    product
  end

  defp valid_attrs(product, attrs \\ %{}) do
    Map.merge(
      %{
        product_id: product.id,
        storage_key: "products/#{product.id}/assets/abc/hero.jpg",
        media_type: "image",
        filename: "hero.jpg",
        mime_type: "image/jpeg",
        byte_size: 12_345,
        uploaded_at: DateTime.utc_now(),
        tags: []
      },
      attrs
    )
  end

  describe "create_asset/1" do
    test "persists a valid asset and defaults status to pending" do
      product = create_product!()

      assert {:ok, %ProductAsset{} = asset} =
               ProductAssets.create_asset(valid_attrs(product))

      assert asset.status == "pending"
      assert asset.media_type == "image"
      assert asset.tags == []
    end

    test "rejects missing required fields" do
      assert {:error, changeset} = ProductAssets.create_asset(%{})

      errors = errors_on(changeset)
      assert "can't be blank" in Map.get(errors, :product_id, [])
      assert "can't be blank" in Map.get(errors, :storage_key, [])
      assert "can't be blank" in Map.get(errors, :media_type, [])
      assert "can't be blank" in Map.get(errors, :filename, [])
      assert "can't be blank" in Map.get(errors, :mime_type, [])
      assert "can't be blank" in Map.get(errors, :byte_size, [])
      assert "can't be blank" in Map.get(errors, :uploaded_at, [])
    end

    test "rejects unknown media_type" do
      product = create_product!()

      assert {:error, changeset} =
               ProductAssets.create_asset(valid_attrs(product, %{media_type: "audio"}))

      assert "is invalid" in errors_on(changeset).media_type
    end

    test "rejects unknown status" do
      product = create_product!()

      assert {:error, changeset} =
               ProductAssets.create_asset(valid_attrs(product, %{status: "archived"}))

      assert "is invalid" in errors_on(changeset).status
    end

    test "rejects non-positive byte_size" do
      product = create_product!()

      assert {:error, changeset} =
               ProductAssets.create_asset(valid_attrs(product, %{byte_size: 0}))

      assert "must be greater than 0" in errors_on(changeset).byte_size
    end
  end

  describe "get_asset* and get_asset_by_storage_key/2" do
    test "get_asset!/1 returns the row" do
      product = create_product!()
      {:ok, asset} = ProductAssets.create_asset(valid_attrs(product))
      assert ProductAssets.get_asset!(asset.id).id == asset.id
    end

    test "get_asset_by_storage_key/2 matches by (product, storage_key)" do
      product_a = create_product!(%{name: "A"})
      product_b = create_product!(%{name: "B"})

      {:ok, a_asset} =
        ProductAssets.create_asset(
          valid_attrs(product_a, %{storage_key: "products/shared-key.jpg"})
        )

      {:ok, _b_asset} =
        ProductAssets.create_asset(
          valid_attrs(product_b, %{storage_key: "products/shared-key.jpg"})
        )

      # Scoped lookup returns only the row for the asked product.
      assert ProductAssets.get_asset_by_storage_key(product_a.id, "products/shared-key.jpg").id ==
               a_asset.id

      assert ProductAssets.get_asset_by_storage_key(product_a.id, "nope") == nil
    end
  end

  describe "list_assets/2" do
    test "returns product assets newest-uploaded-first and excludes other products" do
      product_a = create_product!(%{name: "A"})
      product_b = create_product!(%{name: "B"})

      older =
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

      newer = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      {:ok, asset_old} =
        ProductAssets.create_asset(
          valid_attrs(product_a, %{
            uploaded_at: older,
            storage_key: "products/#{product_a.id}/old.jpg"
          })
        )

      {:ok, asset_new} =
        ProductAssets.create_asset(
          valid_attrs(product_a, %{
            uploaded_at: newer,
            storage_key: "products/#{product_a.id}/new.jpg"
          })
        )

      {:ok, _other} =
        ProductAssets.create_asset(
          valid_attrs(product_b, %{
            storage_key: "products/#{product_b.id}/other.jpg"
          })
        )

      ids = ProductAssets.list_assets(product_a.id) |> Enum.map(& &1.id)
      assert ids == [asset_new.id, asset_old.id]
    end

    test "filters by tag using array overlap" do
      product = create_product!()

      {:ok, tagged} =
        ProductAssets.create_asset(
          valid_attrs(product, %{
            storage_key: "products/#{product.id}/tagged.jpg",
            tags: ["hero", "launch"]
          })
        )

      {:ok, _untagged} =
        ProductAssets.create_asset(
          valid_attrs(product, %{
            storage_key: "products/#{product.id}/untagged.jpg",
            tags: []
          })
        )

      assert [result] = ProductAssets.list_assets(product.id, tag: "launch")
      assert result.id == tagged.id
      assert ProductAssets.list_assets(product.id, tag: "nope") == []
    end

    test "filters by media_type" do
      product = create_product!()

      {:ok, image} =
        ProductAssets.create_asset(
          valid_attrs(product, %{
            storage_key: "products/#{product.id}/one.jpg",
            media_type: "image"
          })
        )

      {:ok, video} =
        ProductAssets.create_asset(
          valid_attrs(product, %{
            storage_key: "products/#{product.id}/one.mp4",
            media_type: "video",
            mime_type: "video/mp4",
            duration_ms: 12_000
          })
        )

      assert [img] = ProductAssets.list_assets(product.id, media_type: "image")
      assert img.id == image.id

      assert [vid] = ProductAssets.list_assets(product.id, media_type: "video")
      assert vid.id == video.id
    end

    test "excludes deleted assets by default but includes them when status filter asks" do
      product = create_product!()
      {:ok, keep} = ProductAssets.create_asset(valid_attrs(product))

      {:ok, gone} =
        ProductAssets.create_asset(
          valid_attrs(product, %{storage_key: "products/#{product.id}/gone.jpg"})
        )

      {:ok, _} = ProductAssets.soft_delete_asset(gone)

      ids_default = ProductAssets.list_assets(product.id) |> Enum.map(& &1.id)
      assert ids_default == [keep.id]

      ids_include_deleted =
        ProductAssets.list_assets(product.id, status: ["pending", "processed", "deleted"])
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert ids_include_deleted == Enum.sort([keep.id, gone.id])
    end

    test "respects :limit" do
      product = create_product!()

      for i <- 1..5 do
        {:ok, _} =
          ProductAssets.create_asset(
            valid_attrs(product, %{storage_key: "products/#{product.id}/#{i}.jpg"})
          )
      end

      assert length(ProductAssets.list_assets(product.id, limit: 2)) == 2
    end
  end

  describe "list_distinct_tags/1" do
    test "returns sorted unique tags across non-deleted assets only" do
      product = create_product!()

      {:ok, _} =
        ProductAssets.create_asset(
          valid_attrs(product, %{
            storage_key: "products/#{product.id}/1.jpg",
            tags: ["hero", "launch"]
          })
        )

      {:ok, _} =
        ProductAssets.create_asset(
          valid_attrs(product, %{
            storage_key: "products/#{product.id}/2.jpg",
            tags: ["launch", "hiring"]
          })
        )

      {:ok, deleted} =
        ProductAssets.create_asset(
          valid_attrs(product, %{
            storage_key: "products/#{product.id}/3.jpg",
            tags: ["only-in-deleted"]
          })
        )

      {:ok, _} = ProductAssets.soft_delete_asset(deleted)

      assert ProductAssets.list_distinct_tags(product.id) == ["hero", "hiring", "launch"]
    end
  end

  describe "mark_processed/2 and mark_failed/2" do
    test "mark_processed moves pending -> processed and writes dimensions" do
      product = create_product!()
      {:ok, asset} = ProductAssets.create_asset(valid_attrs(product))

      assert {:ok, updated} =
               ProductAssets.mark_processed(asset, %{
                 width: 1200,
                 height: 800,
                 duration_ms: nil
               })

      assert updated.status == "processed"
      assert updated.width == 1200
      assert updated.height == 800
      assert updated.error == nil
    end

    test "mark_failed moves status to failed and records the reason" do
      product = create_product!()
      {:ok, asset} = ProductAssets.create_asset(valid_attrs(product))

      assert {:ok, updated} =
               ProductAssets.mark_failed(asset, "media_forge_unavailable")

      assert updated.status == "failed"
      assert updated.error == "media_forge_unavailable"
    end
  end

  describe "soft_delete_asset/1" do
    test "sets status to deleted without removing the row" do
      product = create_product!()
      {:ok, asset} = ProductAssets.create_asset(valid_attrs(product))

      assert {:ok, deleted} = ProductAssets.soft_delete_asset(asset)
      assert deleted.status == "deleted"

      # Row still exists when fetched by id
      assert ProductAssets.get_asset!(asset.id).status == "deleted"

      # But is hidden from default list
      assert ProductAssets.list_assets(product.id) == []
    end
  end

  describe "add_tag/2" do
    test "appends a new tag and broadcasts asset_updated" do
      product = create_product!()
      {:ok, asset} = ProductAssets.create_asset(valid_attrs(product))
      :ok = ProductAssets.subscribe(product.id)

      assert {:ok, updated} = ProductAssets.add_tag(asset, "launch")
      assert "launch" in updated.tags

      assert_receive {:asset_updated, ^updated}
    end

    test "is idempotent: adding an existing tag does not duplicate" do
      product = create_product!()
      {:ok, asset} = ProductAssets.create_asset(valid_attrs(product, %{tags: ["hero"]}))

      assert {:ok, updated} = ProductAssets.add_tag(asset, "hero")
      assert updated.tags == ["hero"]
    end

    test "trims whitespace and skips empty tags" do
      product = create_product!()
      {:ok, asset} = ProductAssets.create_asset(valid_attrs(product))

      assert {:ok, updated} = ProductAssets.add_tag(asset, "   ")
      assert updated.tags == []

      assert {:ok, updated} = ProductAssets.add_tag(asset, "  hero  ")
      assert updated.tags == ["hero"]
    end
  end

  describe "remove_tag/2" do
    test "removes a tag and broadcasts asset_updated" do
      product = create_product!()

      {:ok, asset} =
        ProductAssets.create_asset(valid_attrs(product, %{tags: ["hero", "launch"]}))

      :ok = ProductAssets.subscribe(product.id)

      assert {:ok, updated} = ProductAssets.remove_tag(asset, "hero")
      assert updated.tags == ["launch"]

      assert_receive {:asset_updated, ^updated}
    end

    test "is a no-op when the tag is not present" do
      product = create_product!()
      {:ok, asset} = ProductAssets.create_asset(valid_attrs(product, %{tags: ["hero"]}))

      assert {:ok, updated} = ProductAssets.remove_tag(asset, "not-there")
      assert updated.tags == ["hero"]
    end
  end

  describe "list_assets/2 :search filter" do
    setup do
      product = create_product!()

      {:ok, hero} =
        ProductAssets.create_asset(
          valid_attrs(product, %{
            storage_key: "products/#{product.id}/h.jpg",
            tags: ["hero", "launch"],
            description: "Hero shot for the launch page."
          })
        )

      {:ok, demo} =
        ProductAssets.create_asset(
          valid_attrs(product, %{
            storage_key: "products/#{product.id}/d.mp4",
            media_type: "video",
            mime_type: "video/mp4",
            tags: ["demo"],
            description: "Screen-capture walkthrough."
          })
        )

      %{product: product, hero: hero, demo: demo}
    end

    test "matches a tag substring", %{product: product, hero: hero} do
      [match] = ProductAssets.list_assets(product.id, search: "laun")
      assert match.id == hero.id
    end

    test "matches a description substring (case-insensitive)",
         %{product: product, demo: demo} do
      [match] = ProductAssets.list_assets(product.id, search: "WALKTHROUGH")
      assert match.id == demo.id
    end

    test "composes with media_type", %{product: product, demo: demo} do
      [match] =
        ProductAssets.list_assets(product.id, search: "demo", media_type: "video")

      assert match.id == demo.id

      assert ProductAssets.list_assets(product.id, search: "demo", media_type: "image") ==
               []
    end

    test "returns [] when nothing matches", %{product: product} do
      assert ProductAssets.list_assets(product.id, search: "xyzzy") == []
    end
  end

  describe "top_tags/2" do
    test "returns top tags by count then alphabetically" do
      product = create_product!()

      {:ok, _} =
        ProductAssets.create_asset(
          valid_attrs(product, %{
            storage_key: "products/#{product.id}/1.jpg",
            tags: ["hero", "launch"]
          })
        )

      {:ok, _} =
        ProductAssets.create_asset(
          valid_attrs(product, %{
            storage_key: "products/#{product.id}/2.jpg",
            tags: ["hero", "campaign"]
          })
        )

      {:ok, _} =
        ProductAssets.create_asset(
          valid_attrs(product, %{
            storage_key: "products/#{product.id}/3.jpg",
            tags: ["hero"]
          })
        )

      assert ProductAssets.top_tags(product.id, 2) == [{"hero", 3}, {"campaign", 1}]
    end

    test "excludes deleted assets" do
      product = create_product!()

      {:ok, live_asset} =
        ProductAssets.create_asset(
          valid_attrs(product, %{
            storage_key: "products/#{product.id}/1.jpg",
            tags: ["alive"]
          })
        )

      {:ok, gone} =
        ProductAssets.create_asset(
          valid_attrs(product, %{
            storage_key: "products/#{product.id}/2.jpg",
            tags: ["dead"]
          })
        )

      {:ok, _} = ProductAssets.soft_delete_asset(gone)
      _ = live_asset

      tags = ProductAssets.top_tags(product.id)
      assert Enum.any?(tags, fn {t, _} -> t == "alive" end)
      refute Enum.any?(tags, fn {t, _} -> t == "dead" end)
    end
  end

  describe "partial unique index on (product_id, storage_key)" do
    test "rejects a duplicate storage_key while the original is still active" do
      product = create_product!()
      {:ok, _first} = ProductAssets.create_asset(valid_attrs(product))

      assert {:error, changeset} = ProductAssets.create_asset(valid_attrs(product))

      assert "already registered for this product" in Map.get(
               errors_on(changeset),
               :product_id_storage_key,
               []
             ) or
               "already registered for this product" in Map.get(
                 errors_on(changeset),
                 :storage_key,
                 []
               ) or
               Enum.any?(errors_on(changeset), fn {_k, msgs} ->
                 "already registered for this product" in msgs
               end)
    end

    test "allows a new row with the same storage_key once the original is soft-deleted" do
      product = create_product!()
      {:ok, first} = ProductAssets.create_asset(valid_attrs(product))
      {:ok, _} = ProductAssets.soft_delete_asset(first)

      assert {:ok, _second} = ProductAssets.create_asset(valid_attrs(product))
    end
  end
end
