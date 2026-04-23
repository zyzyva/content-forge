defmodule ContentForgeWeb.DashboardLiveTest do
  use ContentForgeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog

  alias ContentForge.Products
  alias ContentForge.ContentGeneration

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
