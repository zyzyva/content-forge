defmodule ContentForgeWeb.Live.Dashboard.Products.DetailLiveWebhooksTest do
  @moduledoc """
  Phase 16-tail coverage for the Webhooks tab on the product
  detail LiveView. Pre-rework the module aggregate sat at 58%
  with no Webhooks-tab test coverage at all (every handle_event
  for create / edit / update / cancel / delete / toggle was
  uncovered).

  These tests exercise positive paths through the LiveView's
  Webhooks tab using `Phoenix.LiveViewTest` so a regression that
  silently breaks one of the handlers shows up in CI.
  """

  use ContentForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ContentForge.Products

  defp create_product! do
    {:ok, product} =
      Products.create_product(%{
        name: "Webhooks Tab Co #{System.unique_integer()}",
        voice_profile: "professional"
      })

    product
  end

  defp create_generic_webhook!(product, overrides \\ %{}) do
    base = %{
      product_id: product.id,
      url: "https://hooks.example.com/cf",
      platform: "generic",
      generic_auth_type: "none",
      active: true
    }

    {:ok, webhook} = Products.create_blog_webhook(Map.merge(base, overrides))
    webhook
  end

  defp open_webhooks_tab(conn, product) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/products/#{product.id}")
    html = render_click(view, "switch_tab", %{"tab" => "webhooks"})
    {view, html}
  end

  describe "create_webhook" do
    test "inserts a generic webhook and renders it in the table", %{conn: conn} do
      product = create_product!()
      {view, html} = open_webhooks_tab(conn, product)

      refute html =~ "https://hooks.example.com/cf"

      html =
        render_submit(view, "create_webhook", %{
          "webhook" => %{
            "url" => "https://hooks.example.com/cf",
            "platform" => "generic",
            "generic_auth_type" => "none",
            "active" => "true"
          }
        })

      assert html =~ "https://hooks.example.com/cf"
      assert [_] = Products.list_blog_webhooks_for_product(product.id)
    end

    test "renders a changeset error without inserting on missing url", %{conn: conn} do
      product = create_product!()
      {view, _html} = open_webhooks_tab(conn, product)

      _html =
        render_submit(view, "create_webhook", %{
          "webhook" => %{"platform" => "generic"}
        })

      assert Products.list_blog_webhooks_for_product(product.id) == []
    end
  end

  describe "edit_webhook + cancel_webhook_edit" do
    test "edit_webhook puts the row into edit mode (form values prefilled)", %{conn: conn} do
      product = create_product!()
      webhook = create_generic_webhook!(product)
      {view, _html} = open_webhooks_tab(conn, product)

      html = render_click(view, "edit_webhook", %{"webhook-id" => webhook.id})

      assert html =~ "https://hooks.example.com/cf"
      # The cancel button is shown only when an edit is in flight.
      assert html =~ "phx-click=\"cancel_webhook_edit\""
    end

    test "cancel_webhook_edit clears the editing state", %{conn: conn} do
      product = create_product!()
      webhook = create_generic_webhook!(product)
      {view, _html} = open_webhooks_tab(conn, product)

      _ = render_click(view, "edit_webhook", %{"webhook-id" => webhook.id})
      html = render_click(view, "cancel_webhook_edit", %{})

      refute html =~ "phx-click=\"cancel_webhook_edit\""
    end
  end

  describe "update_webhook" do
    test "applies the changes to the row", %{conn: conn} do
      product = create_product!()
      webhook = create_generic_webhook!(product)
      {view, _html} = open_webhooks_tab(conn, product)

      _ = render_click(view, "edit_webhook", %{"webhook-id" => webhook.id})

      html =
        render_submit(view, "update_webhook", %{
          "webhook" => %{
            "url" => "https://hooks.example.com/updated",
            "platform" => "generic",
            "generic_auth_type" => "bearer",
            "generic_bearer_token" => "rotated-tok",
            "active" => "true"
          }
        })

      assert html =~ "https://hooks.example.com/updated"
      reloaded = Products.get_blog_webhook!(webhook.id)
      assert reloaded.url == "https://hooks.example.com/updated"
      assert reloaded.generic_auth_type == "bearer"
      assert reloaded.generic_bearer_token == "rotated-tok"
    end

    test "leaves edit mode after a successful update", %{conn: conn} do
      product = create_product!()
      webhook = create_generic_webhook!(product)
      {view, _html} = open_webhooks_tab(conn, product)

      _ = render_click(view, "edit_webhook", %{"webhook-id" => webhook.id})

      html =
        render_submit(view, "update_webhook", %{
          "webhook" => %{
            "url" => "https://hooks.example.com/cf",
            "platform" => "generic",
            "generic_auth_type" => "none"
          }
        })

      refute html =~ "phx-click=\"cancel_webhook_edit\""
    end
  end

  describe "delete_webhook" do
    test "removes the row from the database and the rendered table", %{conn: conn} do
      product = create_product!()
      webhook = create_generic_webhook!(product)
      {view, html} = open_webhooks_tab(conn, product)

      assert html =~ "https://hooks.example.com/cf"

      html = render_click(view, "delete_webhook", %{"webhook-id" => webhook.id})

      refute html =~ "https://hooks.example.com/cf"
      assert Products.list_blog_webhooks_for_product(product.id) == []
    end
  end

  describe "toggle_webhook_active" do
    test "flips the active flag on the row", %{conn: conn} do
      product = create_product!()
      webhook = create_generic_webhook!(product, %{active: true})
      {view, _html} = open_webhooks_tab(conn, product)

      _ = render_click(view, "toggle_webhook_active", %{"webhook-id" => webhook.id})

      assert Products.get_blog_webhook!(webhook.id).active == false

      _ = render_click(view, "toggle_webhook_active", %{"webhook-id" => webhook.id})

      assert Products.get_blog_webhook!(webhook.id).active == true
    end
  end

  describe "WordPress conditional fields" do
    test "form re-renders with WP fields when platform is set to wordpress", %{conn: conn} do
      product = create_product!()

      {:ok, wp} =
        Products.create_blog_webhook(%{
          product_id: product.id,
          url: "https://hooks.example.com/cf",
          platform: "wordpress",
          wp_site_url: "https://example.com",
          wp_username: "alice",
          wp_app_password: "abcd 1234 efgh 5678"
        })

      {view, _html} = open_webhooks_tab(conn, product)
      html = render_click(view, "edit_webhook", %{"webhook-id" => wp.id})

      assert html =~ "wp_site_url"
      assert html =~ "https://example.com"
      assert html =~ "wp_username"
    end
  end
end
