defmodule ContentForge.OpenClawTools.ListRecentAssetsTest do
  @moduledoc """
  Phase 16.2 read-only tool: lists the product's recent non-deleted
  assets. Product resolution is delegated to `ProductResolver`
  (covered in `product_resolver_test.exs`); this file focuses on
  filter / clamp / shape behavior.
  """
  use ContentForge.DataCase, async: false

  alias ContentForge.OpenClawTools.ListRecentAssets
  alias ContentForge.ProductAssets
  alias ContentForge.Products

  setup do
    {:ok, product} =
      Products.create_product(%{name: "Assetland", voice_profile: "warm"})

    %{product: product}
  end

  defp insert_asset(product, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    base = %{
      product_id: product.id,
      storage_key: "products/#{product.id}/assets/#{Ecto.UUID.generate()}",
      media_type: "image",
      filename: "a.jpg",
      mime_type: "image/jpeg",
      byte_size: 1024,
      uploaded_at: now
    }

    {:ok, asset} = ProductAssets.create_asset(Map.merge(base, attrs))
    asset
  end

  describe "call/2" do
    test "returns recent non-deleted assets for the resolved product", %{product: product} do
      _old =
        insert_asset(product, %{
          filename: "old.jpg",
          uploaded_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        })

      _recent =
        insert_asset(product, %{
          filename: "fresh.jpg",
          uploaded_at: DateTime.add(DateTime.utc_now(), -30, :second)
        })

      _deleted =
        insert_asset(product, %{filename: "gone.jpg", status: "deleted"})

      assert {:ok, result} =
               ListRecentAssets.call(%{}, %{"product" => product.id})

      assert result.product_id == product.id
      assert result.product_name == "Assetland"
      assert result.count == 2

      filenames = Enum.map(result.assets, & &1.filename)
      assert "fresh.jpg" in filenames
      assert "old.jpg" in filenames
      refute "gone.jpg" in filenames

      # Newest first + ISO-8601 uploaded_at strings
      [first | _] = result.assets
      assert first.filename == "fresh.jpg"
      assert is_binary(first.uploaded_at)
      assert match?(%{year: _}, DateTime.from_iso8601(first.uploaded_at) |> elem(1))
      assert first.tags == []
    end

    test "clamps limit between 1 and 50", %{product: product} do
      for i <- 1..3 do
        insert_asset(product, %{
          filename: "a#{i}.jpg",
          uploaded_at: DateTime.add(DateTime.utc_now(), -i * 10, :second)
        })
      end

      {:ok, zero} = ListRecentAssets.call(%{}, %{"product" => product.id, "limit" => 0})
      assert zero.count == 1

      {:ok, huge} = ListRecentAssets.call(%{}, %{"product" => product.id, "limit" => 999})
      assert huge.count == 3

      {:ok, one} = ListRecentAssets.call(%{}, %{"product" => product.id, "limit" => 1})
      assert one.count == 1
    end

    test "filters by media_type when supplied", %{product: product} do
      insert_asset(product, %{filename: "pic.jpg", media_type: "image"})
      insert_asset(product, %{filename: "clip.mp4", media_type: "video", mime_type: "video/mp4"})

      {:ok, images} =
        ListRecentAssets.call(%{}, %{"product" => product.id, "media_type" => "image"})

      assert Enum.all?(images.assets, &(&1.media_type == "image"))

      {:ok, videos} =
        ListRecentAssets.call(%{}, %{"product" => product.id, "media_type" => "video"})

      assert Enum.all?(videos.assets, &(&1.media_type == "video"))
    end

    test "filters by tag (array overlap) when supplied", %{product: product} do
      insert_asset(product, %{filename: "with.jpg", tags: ["spring", "promo"]})
      insert_asset(product, %{filename: "without.jpg", tags: ["winter"]})

      {:ok, result} =
        ListRecentAssets.call(%{}, %{"product" => product.id, "tag" => "spring"})

      assert result.count == 1
      assert [%{filename: "with.jpg"}] = result.assets
    end

    test "returns :missing_product_context when no product and no SMS session" do
      assert {:error, :missing_product_context} =
               ListRecentAssets.call(%{channel: "cli", sender_identity: "cli:ops"}, %{})
    end

    test "returns :product_not_found when the product name has no match" do
      assert {:error, :product_not_found} =
               ListRecentAssets.call(%{}, %{"product" => "does-not-exist"})
    end
  end
end
