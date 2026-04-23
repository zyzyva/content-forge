defmodule ContentForgeWeb.DashboardLiveTest do
  use ContentForgeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog

  alias ContentForge.ContentGeneration
  alias ContentForge.ContentGeneration.Draft
  alias ContentForge.Products
  alias ContentForge.Repo

  defp create_product(attrs \\ %{}) do
    defaults = %{name: "Test Product", voice_profile: "professional"}
    {:ok, product} = Products.create_product(Map.merge(defaults, attrs))
    product
  end

  defp create_draft(product, attrs \\ %{}) do
    defaults = %{
      product_id: product.id,
      content: "Test draft content for the review queue",
      platform: "twitter",
      content_type: "post",
      generating_model: "claude"
    }

    {:ok, draft} = ContentGeneration.create_draft(Map.merge(defaults, attrs))
    draft
  end

  describe "Products list page" do
    test "mounts successfully and shows Products heading", %{conn: conn} do
      _product = create_product()

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      assert render(view) =~ "Products"
    end

    test "shows products from the database", %{conn: conn} do
      product = create_product(%{name: "My Awesome SaaS"})

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      assert render(view) =~ product.name
    end

    test "shows empty state when no products exist", %{conn: conn} do
      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      assert render(view) =~ "No products found"
    end
  end

  describe "Product detail page" do
    test "mounts with a valid product_id", %{conn: conn} do
      product = create_product(%{name: "Detail Test Product"})

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products/#{product.id}")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      assert render(view) =~ product.name
    end

    test "shows voice profile on the detail page", %{conn: conn} do
      product = create_product(%{name: "VP Product", voice_profile: "casual"})

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products/#{product.id}")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      html = render(view)
      assert html =~ "casual"
    end

    test "shows tab navigation", %{conn: conn} do
      product = create_product()

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products/#{product.id}")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      html = render(view)
      assert html =~ "Overview"
      assert html =~ "Briefs"
      assert html =~ "Drafts"
      assert html =~ "History"
      assert html =~ "Assets"
    end

    test "Assets tab renders the upload form and an empty assets section",
         %{conn: conn} do
      product = create_product(%{name: "Assets Product"})

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products/#{product.id}")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}

      html = render_click(view, "switch_tab", %{"tab" => "assets"})

      assert html =~ "Upload Assets"
      assert html =~ "Register uploads"
      assert html =~ "No assets match"
      assert html =~ "Search tags or description"
    end

    test "Assets tab lists existing product assets with status badges",
         %{conn: conn} do
      product = create_product(%{name: "With Assets"})

      {:ok, asset} =
        ContentForge.ProductAssets.create_asset(%{
          product_id: product.id,
          storage_key: "products/#{product.id}/assets/abc/hero.jpg",
          media_type: "image",
          filename: "hero.jpg",
          mime_type: "image/jpeg",
          byte_size: 10_240,
          uploaded_at: DateTime.utc_now()
        })

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products/#{product.id}")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}

      html = render_click(view, "switch_tab", %{"tab" => "assets"})

      assert html =~ "hero.jpg"
      assert html =~ "PENDING"
      assert html =~ "asset-#{asset.id}"
    end

    test "Assets tab: adding a tag renders a chip and a new facet",
         %{conn: conn} do
      product = create_product(%{name: "Tag Product"})

      {:ok, asset} =
        ContentForge.ProductAssets.create_asset(%{
          product_id: product.id,
          storage_key: "products/#{product.id}/assets/a/t.jpg",
          media_type: "image",
          filename: "t.jpg",
          mime_type: "image/jpeg",
          byte_size: 1024,
          uploaded_at: DateTime.utc_now()
        })

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products/#{product.id}")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      _ = render_click(view, "switch_tab", %{"tab" => "assets"})

      html =
        render_submit(view, "add_tag", %{"asset-id" => asset.id, "tag" => "launch"})

      assert html =~ ~s|data-asset-tag="launch"|
      assert html =~ "launch (1)"
    end

    test "Assets tab: removing a tag drops its chip",
         %{conn: conn} do
      product = create_product(%{name: "Remove Tag Product"})

      {:ok, asset} =
        ContentForge.ProductAssets.create_asset(%{
          product_id: product.id,
          storage_key: "products/#{product.id}/assets/a/r.jpg",
          media_type: "image",
          filename: "r.jpg",
          mime_type: "image/jpeg",
          byte_size: 1024,
          uploaded_at: DateTime.utc_now(),
          tags: ["keep", "discard"]
        })

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products/#{product.id}")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      _ = render_click(view, "switch_tab", %{"tab" => "assets"})

      html =
        render_click(view, "remove_tag", %{"asset-id" => asset.id, "tag" => "discard"})

      refute html =~ ~s|data-asset-tag="discard"|
      assert html =~ ~s|data-asset-tag="keep"|
    end

    test "Assets tab: search filters by tag substring",
         %{conn: conn} do
      product = create_product(%{name: "Search Product"})

      {:ok, _} =
        ContentForge.ProductAssets.create_asset(%{
          product_id: product.id,
          storage_key: "products/#{product.id}/assets/a/hero.jpg",
          media_type: "image",
          filename: "hero.jpg",
          mime_type: "image/jpeg",
          byte_size: 1024,
          uploaded_at: DateTime.utc_now(),
          tags: ["launch"]
        })

      {:ok, _other} =
        ContentForge.ProductAssets.create_asset(%{
          product_id: product.id,
          storage_key: "products/#{product.id}/assets/a/other.jpg",
          media_type: "image",
          filename: "other.jpg",
          mime_type: "image/jpeg",
          byte_size: 1024,
          uploaded_at: DateTime.utc_now(),
          tags: ["misc"]
        })

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products/#{product.id}")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      _ = render_click(view, "switch_tab", %{"tab" => "assets"})

      html =
        render_change(view, "search_assets", %{"search" => "laun", "media_type" => ""})

      assert html =~ "hero.jpg"
      refute html =~ "other.jpg"
    end

    test "Assets tab: clicking a tag facet prefills search and filters",
         %{conn: conn} do
      product = create_product(%{name: "Facet Product"})

      {:ok, _} =
        ContentForge.ProductAssets.create_asset(%{
          product_id: product.id,
          storage_key: "products/#{product.id}/assets/a/hero.jpg",
          media_type: "image",
          filename: "hero.jpg",
          mime_type: "image/jpeg",
          byte_size: 1024,
          uploaded_at: DateTime.utc_now(),
          tags: ["launch"]
        })

      {:ok, _} =
        ContentForge.ProductAssets.create_asset(%{
          product_id: product.id,
          storage_key: "products/#{product.id}/assets/a/demo.mp4",
          media_type: "video",
          filename: "demo.mp4",
          mime_type: "video/mp4",
          byte_size: 2048,
          uploaded_at: DateTime.utc_now(),
          tags: ["walkthrough"]
        })

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products/#{product.id}")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      _ = render_click(view, "switch_tab", %{"tab" => "assets"})

      html = render_click(view, "use_facet", %{"tag" => "launch"})

      assert html =~ "hero.jpg"
      refute html =~ "demo.mp4"
      # Search input reflects the clicked facet value
      assert html =~ ~s|value="launch"|
    end

    test "PubSub broadcast flips the asset status badge to PROCESSED",
         %{conn: conn} do
      product = create_product(%{name: "Live Asset Updates"})

      {:ok, asset} =
        ContentForge.ProductAssets.create_asset(%{
          product_id: product.id,
          storage_key: "products/#{product.id}/assets/abc/live.jpg",
          media_type: "image",
          filename: "live.jpg",
          mime_type: "image/jpeg",
          byte_size: 2048,
          uploaded_at: DateTime.utc_now()
        })

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products/#{product.id}")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}

      initial_html = render_click(view, "switch_tab", %{"tab" => "assets"})
      assert initial_html =~ "PENDING"

      {:ok, _processed} =
        ContentForge.ProductAssets.mark_processed(asset, %{
          width: 1200,
          height: 800
        })

      :ok = render_async_wait(view)

      updated_html = render(view)
      assert updated_html =~ "PROCESSED"
      refute updated_html =~ "PENDING"
    end

    # Renders and waits briefly so PubSub-delivered messages can be processed
    # by the LiveView before we inspect the rendered HTML.
    defp render_async_wait(view, timeout \\ 100) do
      Process.sleep(timeout)
      render(view)
      :ok
    end
  end

  describe "Product bundles tab" do
    alias ContentForge.ProductAssets

    defp create_asset!(product, overrides) do
      defaults = %{
        product_id: product.id,
        storage_key:
          "products/#{product.id}/assets/#{Ecto.UUID.generate()}/#{Map.get(overrides, :filename, "file.jpg")}",
        media_type: "image",
        filename: "file.jpg",
        mime_type: "image/jpeg",
        byte_size: 1024,
        uploaded_at: DateTime.utc_now(),
        tags: []
      }

      {:ok, asset} = ProductAssets.create_asset(Map.merge(defaults, overrides))
      asset
    end

    test "Bundles tab renders empty state and a create-bundle form", %{conn: conn} do
      product = create_product(%{name: "Bundle Home"})

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products/#{product.id}")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      html = render_click(view, "switch_tab", %{"tab" => "bundles"})

      assert html =~ "Asset Bundles"
      assert html =~ "No bundles yet"
      assert html =~ "Create bundle"
      assert html =~ ~s|name="bundle[name]"|
      assert html =~ ~s|name="bundle[context]"|
    end

    test "create_bundle event inserts a bundle and lists it", %{conn: conn} do
      product = create_product(%{name: "Create Bundle"})

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products/#{product.id}")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      _ = render_click(view, "switch_tab", %{"tab" => "bundles"})

      html =
        render_submit(view, "create_bundle", %{
          "bundle" => %{
            "name" => "Johnson kitchen remodel",
            "context" => "Quartz counters, 3 weeks"
          }
        })

      assert html =~ "Johnson kitchen remodel"
      assert html =~ "0 assets"
      refute html =~ "No bundles yet"
    end

    test "create_bundle shows a validation error for missing name", %{conn: conn} do
      product = create_product(%{name: "Create Bundle Err"})

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products/#{product.id}")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      _ = render_click(view, "switch_tab", %{"tab" => "bundles"})

      html =
        render_submit(view, "create_bundle", %{
          "bundle" => %{"name" => "", "context" => ""}
        })

      assert html =~ "can&#39;t be blank"
    end

    test "bundle card shows asset count and thumbnail mosaic", %{conn: conn} do
      product = create_product(%{name: "Mosaic"})
      {:ok, bundle} = ProductAssets.create_bundle(%{product_id: product.id, name: "Mosaic B"})
      a1 = create_asset!(product, %{filename: "a.jpg"})
      a2 = create_asset!(product, %{filename: "b.jpg"})
      {:ok, _} = ProductAssets.add_asset_to_bundle(bundle, a1)
      {:ok, _} = ProductAssets.add_asset_to_bundle(bundle, a2)

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products/#{product.id}")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      html = render_click(view, "switch_tab", %{"tab" => "bundles"})

      assert html =~ "Mosaic B"
      assert html =~ "2 assets"
      assert html =~ ~s|id="bundle-#{bundle.id}"|
      assert html =~ ~s|data-bundle-thumb="#{a1.id}"|
      assert html =~ ~s|data-bundle-thumb="#{a2.id}"|
    end

    test "open_bundle expands the drawer with asset list", %{conn: conn} do
      product = create_product(%{name: "Open Drawer"})
      {:ok, bundle} = ProductAssets.create_bundle(%{product_id: product.id, name: "Drawer B"})
      asset = create_asset!(product, %{filename: "hero.jpg"})
      {:ok, _} = ProductAssets.add_asset_to_bundle(bundle, asset)

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products/#{product.id}")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      _ = render_click(view, "switch_tab", %{"tab" => "bundles"})

      html = render_click(view, "open_bundle", %{"bundle-id" => bundle.id})

      assert html =~ ~s|id="bundle-detail-#{bundle.id}"|
      assert html =~ "hero.jpg"
      assert html =~ ~s|data-bundle-asset-row="#{asset.id}"|
    end

    test "remove_bundle_asset removes an asset from the bundle", %{conn: conn} do
      product = create_product(%{name: "Remove"})
      {:ok, bundle} = ProductAssets.create_bundle(%{product_id: product.id, name: "Remove B"})
      asset = create_asset!(product, %{filename: "drop.jpg"})
      {:ok, _} = ProductAssets.add_asset_to_bundle(bundle, asset)

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products/#{product.id}")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      _ = render_click(view, "switch_tab", %{"tab" => "bundles"})
      _ = render_click(view, "open_bundle", %{"bundle-id" => bundle.id})

      html =
        render_click(view, "remove_bundle_asset", %{
          "bundle-id" => bundle.id,
          "asset-id" => asset.id
        })

      refute html =~ ~s|data-bundle-asset-row="#{asset.id}"|
      assert html =~ "0 assets"
    end

    test "reorder_bundle_asset direction=up swaps order", %{conn: conn} do
      product = create_product(%{name: "Reorder"})
      {:ok, bundle} = ProductAssets.create_bundle(%{product_id: product.id, name: "Reorder B"})
      a = create_asset!(product, %{filename: "first.jpg"})
      b = create_asset!(product, %{filename: "second.jpg"})
      c = create_asset!(product, %{filename: "third.jpg"})
      {:ok, _} = ProductAssets.add_asset_to_bundle(bundle, a)
      {:ok, _} = ProductAssets.add_asset_to_bundle(bundle, b)
      {:ok, _} = ProductAssets.add_asset_to_bundle(bundle, c)

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products/#{product.id}")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      _ = render_click(view, "switch_tab", %{"tab" => "bundles"})
      _ = render_click(view, "open_bundle", %{"bundle-id" => bundle.id})

      _ =
        render_click(view, "reorder_bundle_asset", %{
          "bundle-id" => bundle.id,
          "asset-id" => c.id,
          "direction" => "up"
        })

      reloaded = ProductAssets.get_bundle!(bundle.id)
      ordered_ids = Enum.map(reloaded.bundle_assets, & &1.asset_id)
      assert ordered_ids == [a.id, c.id, b.id]
    end

    test "add_bundle_asset attaches an unattached asset; picker filters by media type",
         %{conn: conn} do
      product = create_product(%{name: "Picker"})
      {:ok, bundle} = ProductAssets.create_bundle(%{product_id: product.id, name: "Picker B"})
      img = create_asset!(product, %{filename: "only-image.jpg", media_type: "image"})

      vid =
        create_asset!(product, %{
          filename: "clip.mp4",
          media_type: "video",
          mime_type: "video/mp4"
        })

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products/#{product.id}")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      _ = render_click(view, "switch_tab", %{"tab" => "bundles"})
      _ = render_click(view, "open_bundle", %{"bundle-id" => bundle.id})

      filtered =
        render_change(view, "filter_picker_media", %{
          "bundle-id" => bundle.id,
          "media_type" => "image"
        })

      assert filtered =~ "only-image.jpg"
      refute filtered =~ "clip.mp4"

      added =
        render_click(view, "add_bundle_asset", %{
          "bundle-id" => bundle.id,
          "asset-id" => img.id
        })

      assert added =~ ~s|data-bundle-asset-row="#{img.id}"|
      assert added =~ "1 assets"

      # The just-added asset should no longer be offered by the picker.
      refute added =~ ~s|data-picker-asset="#{img.id}"|

      # Video asset is still unattached and selectable when filter is cleared.
      cleared =
        render_change(view, "filter_picker_media", %{
          "bundle-id" => bundle.id,
          "media_type" => ""
        })

      assert cleared =~ ~s|data-picker-asset="#{vid.id}"|
      assert cleared =~ "clip.mp4"
    end

    test "archive_bundle removes it from the default list", %{conn: conn} do
      product = create_product(%{name: "Archive"})
      {:ok, bundle} = ProductAssets.create_bundle(%{product_id: product.id, name: "Trashable"})

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products/#{product.id}")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      _ = render_click(view, "switch_tab", %{"tab" => "bundles"})

      html =
        render_click(view, "archive_bundle", %{"bundle-id" => bundle.id})

      refute html =~ "Trashable"
      assert ProductAssets.get_bundle!(bundle.id).status == "archived"
    end

    test "soft_delete_bundle removes it from the default list", %{conn: conn} do
      product = create_product(%{name: "SoftDel"})
      {:ok, bundle} = ProductAssets.create_bundle(%{product_id: product.id, name: "Doomed"})

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products/#{product.id}")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      _ = render_click(view, "switch_tab", %{"tab" => "bundles"})

      html =
        render_click(view, "soft_delete_bundle", %{"bundle-id" => bundle.id})

      refute html =~ "Doomed"
      assert ProductAssets.get_bundle!(bundle.id).status == "deleted"
    end

    test "PubSub :bundle_created from another process refreshes the list",
         %{conn: conn} do
      product = create_product(%{name: "PubSub Bundles"})

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products/#{product.id}")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      _ = render_click(view, "switch_tab", %{"tab" => "bundles"})

      {:ok, _external} =
        ProductAssets.create_bundle(%{product_id: product.id, name: "Externally created"})

      Process.sleep(100)
      html = render(view)

      assert html =~ "Externally created"
    end
  end

  describe "Draft review page" do
    test "mounts and lists drafts", %{conn: conn} do
      product = create_product()
      _draft = create_draft(product)

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/drafts")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      html = render(view)
      assert html =~ "Draft Review Queue"
    end

    test "shows draft count when drafts exist", %{conn: conn} do
      product = create_product()
      _draft1 = create_draft(product)
      _draft2 = create_draft(product, %{platform: "linkedin"})

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/drafts")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      html = render(view)
      assert html =~ "Drafts (2)"
    end

    test "shows filter tabs", %{conn: conn} do
      capture_log(fn ->
        result = live(conn, ~p"/dashboard/drafts")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      html = render(view)
      assert html =~ "All"
      assert html =~ "Ranked"
      assert html =~ "Approved"
      assert html =~ "Rejected"
    end

    test "shows empty state when no drafts exist", %{conn: conn} do
      capture_log(fn ->
        result = live(conn, ~p"/dashboard/drafts")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      assert render(view) =~ "No drafts found"
    end

    test "exposes a Blocked filter tab", %{conn: conn} do
      capture_log(fn ->
        result = live(conn, ~p"/dashboard/drafts")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      html = render(view)
      assert html =~ "Blocked"
    end

    test "renders a blocked draft with a distinct BLOCKED label", %{conn: conn} do
      product = create_product()
      _draft = create_draft(product, %{status: "blocked"})

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/drafts")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      html = render(view)
      assert html =~ "BLOCKED"
    end

    test "exposes an Archived filter tab", %{conn: conn} do
      capture_log(fn ->
        result = live(conn, ~p"/dashboard/drafts")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      html = render(view)
      assert html =~ ~s|id="filter-tab-archived"|
      assert html =~ "Archived"
    end

    test "renders an archived draft with a distinct ARCHIVED badge", %{conn: conn} do
      product = create_product()
      _draft = create_draft(product, %{status: "archived"})

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/drafts")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      html = render(view)
      assert html =~ "ARCHIVED"
      # Ghost badge class confirms the component picked up the
      # archived branch (not the fallback badge-neutral).
      assert html =~ "badge-ghost"
    end

    test "exposes a Needs Review filter tab", %{conn: conn} do
      capture_log(fn ->
        result = live(conn, ~p"/dashboard/drafts")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      html = render(view)
      assert html =~ ~s|id="filter-tab-needs_review"|
      assert html =~ "Needs Review"
    end

    test "renders a needs_review draft with a warning badge", %{conn: conn} do
      product = create_product()
      _draft = create_draft(product, %{status: "needs_review"})

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/drafts")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      html = render(view)
      assert html =~ "NEEDS_REVIEW"
      assert html =~ "badge-warning"
    end

    test "SEO badge colors by score band", %{conn: conn} do
      product = create_product()
      draft = create_draft(product, %{platform: "blog", content_type: "blog"})

      # Write the score post-creation because the nugget hook /
      # SEO runner compute a score for the default content.
      draft
      |> Draft.changeset(%{seo_score: 25})
      |> Repo.update!()

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/drafts")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      html = render(view)
      assert html =~ ~s|data-seo-score="25"|
      assert html =~ "badge-success"
    end

    test "research badge label + color maps per status", %{conn: conn} do
      product = create_product()
      draft = create_draft(product, %{platform: "blog", content_type: "blog"})

      draft
      |> Draft.changeset(%{research_status: "lost_data_point"})
      |> Repo.update!()

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/drafts")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      html = render(view)
      assert html =~ ~s|data-research-status="lost_data_point"|
      assert html =~ "Missing citation"
    end

    test "approve button on a below-threshold draft opens the override modal",
         %{conn: conn} do
      product = create_product()
      draft = create_draft(product, %{platform: "blog", content_type: "blog"})

      draft
      |> Draft.changeset(%{seo_score: 10})
      |> Repo.update!()

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/drafts")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      html = render_click(view, "approve_draft", %{"id" => draft.id})

      assert html =~ "data-override-modal"
      assert html =~ "Approve via override"
    end

    test "submitting the override modal with a >= 20 char reason approves the draft",
         %{conn: conn} do
      product = create_product()
      draft = create_draft(product, %{platform: "blog", content_type: "blog"})

      draft
      |> Draft.changeset(%{seo_score: 10})
      |> Repo.update!()

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/drafts")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      render_click(view, "approve_draft", %{"id" => draft.id})

      reason = "human editor signed off after review"
      render_submit(view, "submit_override", %{"reason" => reason})

      approved = ContentGeneration.get_draft!(draft.id)
      assert approved.status == "approved"
      assert approved.approved_via_override == true
      assert approved.override_reason == reason
    end

    test "shows SEO score column on blog drafts and opens the drawer on select",
         %{conn: conn} do
      product = create_product()

      blog_content =
        """
        # SEO Sample Title Under Sixty Chars

        <meta name="description" content="A concise meta description well within the 155 character SERP snippet budget for blog article.">

        Stripe: 2.9% + $0.30 per charge, 3-5 day payout, USD and EUR supported. Published Feb 2026 after the Checkout API rewrite that shipped January 15.

        Longer body content continues here with paragraphs talking about the subject.
        """

      draft =
        create_draft(product, %{content: blog_content, platform: "blog", content_type: "blog"})

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/drafts")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}

      # Card list shows the SEO score chip for this blog draft.
      list_html = render(view)
      assert list_html =~ "data-seo-score="
      assert list_html =~ "SEO "

      # Selecting the draft opens the drawer with per-check rows.
      render_click(view, "select_draft", %{"id" => draft.id})
      drawer_html = render(view)

      assert drawer_html =~ "data-seo-checklist-drawer"
      assert drawer_html =~ "SEO Checklist"
      assert drawer_html =~ ~s|data-seo-check="title_length"|
      assert drawer_html =~ ~s|data-seo-check="single_h1"|
      # Stub checks also appear with their not_applicable badge.
      assert drawer_html =~ ~s|data-seo-check="heading_hierarchy"|
      assert drawer_html =~ "not_applicable"
    end
  end

  describe "Schedule page" do
    test "mounts successfully", %{conn: conn} do
      capture_log(fn ->
        result = live(conn, ~p"/dashboard/schedule")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      html = render(view)
      assert html =~ "Schedule"
    end

    test "shows timeline and calendar view options", %{conn: conn} do
      capture_log(fn ->
        result = live(conn, ~p"/dashboard/schedule")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      html = render(view)
      assert html =~ "Timeline"
      assert html =~ "Calendar"
    end

    test "shows stat cards for published and scheduled counts", %{conn: conn} do
      capture_log(fn ->
        result = live(conn, ~p"/dashboard/schedule")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      html = render(view)
      assert html =~ "Published"
      assert html =~ "Scheduled"
    end

    test "surfaces blocked drafts in a distinct section", %{conn: conn} do
      product = create_product()
      _blocked = create_draft(product, %{status: "blocked", image_url: nil})

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/schedule")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      html = render(view)
      assert html =~ "Blocked"
      assert html =~ "BLOCKED"
    end
  end
end
