defmodule ContentForgeWeb.Live.Dashboard.BundleGenerateDraftsTest do
  use ContentForgeWeb.ConnCase, async: false
  use Oban.Testing, repo: ContentForge.Repo

  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog

  alias ContentForge.Jobs.AssetBundleDraftGenerator
  alias ContentForge.ProductAssets
  alias ContentForge.Products

  defp enabled_targets do
    %{
      "twitter" => %{"enabled" => true, "access_token" => "tw"},
      "linkedin" => %{"enabled" => true, "access_token" => "li"},
      # Deliberately disabled - must not render a checkbox.
      "facebook" => %{"enabled" => false, "access_token" => "fb"},
      # Absent from UI (no "enabled" flag at all).
      "instagram" => %{"access_token" => "ig"}
    }
  end

  defp create_product_with_targets!(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          name: "Bundle Gen Product",
          voice_profile: "professional",
          publishing_targets: enabled_targets()
        },
        overrides
      )

    {:ok, product} = Products.create_product(attrs)
    product
  end

  defp create_bundle_with_asset!(product) do
    {:ok, bundle} =
      ProductAssets.create_bundle(%{product_id: product.id, name: "Hero bundle"})

    {:ok, asset} =
      ProductAssets.create_asset(%{
        product_id: product.id,
        storage_key: "products/#{product.id}/assets/#{Ecto.UUID.generate()}/hero.jpg",
        filename: "hero.jpg",
        mime_type: "image/jpeg",
        media_type: "image",
        byte_size: 1024,
        uploaded_at: DateTime.utc_now()
      })

    {:ok, _} = ProductAssets.add_asset_to_bundle(bundle, asset)

    {ProductAssets.get_bundle!(bundle.id), asset}
  end

  defp open_bundles_tab_and_drawer(view, bundle_id) do
    _ = render_click(view, "switch_tab", %{"tab" => "bundles"})
    render_click(view, "open_bundle", %{"bundle-id" => bundle_id})
  end

  describe "Bundle drawer: generate drafts form" do
    test "renders a checkbox per enabled platform and a variants_per_platform input",
         %{conn: conn} do
      product = create_product_with_targets!()
      {bundle, _asset} = create_bundle_with_asset!(product)

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products/#{product.id}")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      html = open_bundles_tab_and_drawer(view, bundle.id)

      assert html =~ "Generate drafts"
      assert html =~ ~s|name="platforms[]" value="twitter"|
      assert html =~ ~s|name="platforms[]" value="linkedin"|
      refute html =~ ~s|name="platforms[]" value="facebook"|
      refute html =~ ~s|name="platforms[]" value="instagram"|

      assert html =~ ~s|name="variants_per_platform"|
      assert html =~ ~s|value="3"|
    end

    test "renders an informational message when no platforms are enabled",
         %{conn: conn} do
      product = create_product_with_targets!(%{publishing_targets: %{}})
      {bundle, _asset} = create_bundle_with_asset!(product)

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products/#{product.id}")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      html = open_bundles_tab_and_drawer(view, bundle.id)

      assert html =~ "No publishing platforms are enabled"
      refute html =~ ~s|name="platforms[]"|
    end
  end

  describe "Bundle drawer: generate_drafts submit" do
    test "enqueues AssetBundleDraftGenerator with bundle_id + platforms + variants",
         %{conn: conn} do
      product = create_product_with_targets!()
      {bundle, _asset} = create_bundle_with_asset!(product)

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products/#{product.id}")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      _ = open_bundles_tab_and_drawer(view, bundle.id)

      html =
        render_submit(view, "generate_drafts", %{
          "bundle-id" => bundle.id,
          "platforms" => ["twitter", "linkedin"],
          "variants_per_platform" => "4"
        })

      assert html =~ "drafts generating"
      assert html =~ ~s|data-bundle-generating="#{bundle.id}"|

      assert_enqueued(
        worker: AssetBundleDraftGenerator,
        args: %{
          "bundle_id" => bundle.id,
          "platforms" => ["twitter", "linkedin"],
          "variants_per_platform" => 4
        }
      )
    end

    test "defaults to variants_per_platform=3 when the input is missing or blank",
         %{conn: conn} do
      product = create_product_with_targets!()
      {bundle, _asset} = create_bundle_with_asset!(product)

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products/#{product.id}")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      _ = open_bundles_tab_and_drawer(view, bundle.id)

      _ =
        render_submit(view, "generate_drafts", %{
          "bundle-id" => bundle.id,
          "platforms" => ["twitter"]
        })

      assert_enqueued(
        worker: AssetBundleDraftGenerator,
        args: %{
          "bundle_id" => bundle.id,
          "platforms" => ["twitter"],
          "variants_per_platform" => 3
        }
      )
    end

    test "does nothing and surfaces an error when no platforms are selected",
         %{conn: conn} do
      product = create_product_with_targets!()
      {bundle, _asset} = create_bundle_with_asset!(product)

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products/#{product.id}")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      _ = open_bundles_tab_and_drawer(view, bundle.id)

      html =
        render_submit(view, "generate_drafts", %{
          "bundle-id" => bundle.id,
          "variants_per_platform" => "3"
        })

      refute_enqueued(worker: AssetBundleDraftGenerator)
      assert html =~ "Select at least one platform"
    end
  end

  describe "generation lifecycle banner" do
    test "banner clears when :bundle_generation_finished arrives on the topic",
         %{conn: conn} do
      product = create_product_with_targets!()
      {bundle, _asset} = create_bundle_with_asset!(product)

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/products/#{product.id}")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}
      _ = open_bundles_tab_and_drawer(view, bundle.id)

      html =
        render_submit(view, "generate_drafts", %{
          "bundle-id" => bundle.id,
          "platforms" => ["twitter"],
          "variants_per_platform" => "2"
        })

      assert html =~ "drafts generating"

      :ok = ProductAssets.broadcast_bundle_generation_finished(product.id, bundle.id)
      Process.sleep(100)

      refreshed = render(view)
      refute refreshed =~ "drafts generating"
      refute refreshed =~ ~s|data-bundle-generating="#{bundle.id}"|
    end
  end
end
