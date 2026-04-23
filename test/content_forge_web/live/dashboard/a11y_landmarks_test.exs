defmodule ContentForgeWeb.Live.Dashboard.A11yLandmarksTest do
  @moduledoc """
  WCAG AA landmark + heading-hierarchy smoke tests for the three
  pages audited in phase 15.2a:

    * `/dashboard`
    * `/dashboard/products`
    * `/dashboard/products/:id`

  Each page must have:

    * exactly one `<h1>` (the page title).
    * a `<main>` landmark wrapping the page content with an
      `id="main-content"` anchor (so a skip-link target exists once
      global nav lands).
    * `<main>` is associated with the `<h1>` via `aria-labelledby`
      pointing at the h1's id.

  The page-specific asserts below also pin a few load-bearing
  aria-labels and label associations that the audit surfaced.
  """
  use ContentForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog

  alias ContentForge.Products

  defp live_at(conn, path) do
    capture_log(fn ->
      result = live(conn, path)
      send(self(), {:result, result})
    end)

    assert_received {:result, {:ok, view, html}}
    {view, html}
  end

  defp count_matches(html, pattern) do
    Regex.scan(pattern, html) |> length()
  end

  describe "/dashboard" do
    test "has one <h1>, a <main> landmark, and a dashboard nav", %{conn: conn} do
      {_view, html} = live_at(conn, ~p"/dashboard")

      assert count_matches(html, ~r|<h1\b|) == 1
      assert count_matches(html, ~r|<main\b|) == 1
      assert html =~ ~s|id="main-content"|
      assert html =~ ~s|aria-labelledby="page-title"|
      assert html =~ ~s|aria-label="Dashboard sections"|
    end
  end

  describe "/dashboard/products" do
    test "has one <h1>, a <main> landmark, and labeled form inputs",
         %{conn: conn} do
      {_view, html} = live_at(conn, ~p"/dashboard/products")

      assert count_matches(html, ~r|<h1\b|) == 1
      assert count_matches(html, ~r|<main\b|) == 1
      assert html =~ ~s|id="main-content"|
      assert html =~ ~s|aria-labelledby="page-title"|

      # Every <input> has an accessible name (aria-label OR wrapped
      # in a <label>). The audit added aria-label attributes.
      assert html =~ ~s|aria-label="Product name"|
      assert html =~ ~s|aria-label="Voice profile"|
      assert html =~ ~s|aria-label="Search products"|
    end

    test "delete button has an aria-label referencing the product",
         %{conn: conn} do
      {:ok, product} =
        Products.create_product(%{
          name: "Labeled Product",
          voice_profile: "professional"
        })

      {_view, html} = live_at(conn, ~p"/dashboard/products")

      assert html =~ "aria-label=\"Delete product #{product.name}\""
    end
  end

  describe "/dashboard/products/:id" do
    test "has one <h1>, a <main> landmark, and a back-link aria-label",
         %{conn: conn} do
      {:ok, product} =
        Products.create_product(%{
          name: "Detail Product",
          voice_profile: "casual"
        })

      {_view, html} = live_at(conn, ~p"/dashboard/products/#{product.id}")

      assert count_matches(html, ~r|<h1\b|) == 1
      assert count_matches(html, ~r|<main\b|) == 1
      assert html =~ ~s|id="main-content"|
      assert html =~ ~s|aria-labelledby="page-title"|
      assert html =~ ~s|aria-label="Back to products list"|
    end
  end

  describe "/dashboard/drafts" do
    test "has one <h1>, a <main> landmark, tablist filter, labeled product select",
         %{conn: conn} do
      {_view, html} = live_at(conn, ~p"/dashboard/drafts")

      assert count_matches(html, ~r|<h1\b|) == 1
      assert count_matches(html, ~r|<main\b|) == 1
      assert html =~ ~s|id="main-content"|
      assert html =~ ~s|aria-labelledby="page-title"|

      # Filter tabs: role=tablist + aria-label + at least one
      # aria-selected="true" among the tabs.
      assert html =~ ~s|role="tablist"|
      assert html =~ ~s|aria-label="Draft status filter"|
      assert html =~ ~s|role="tab"|
      assert html =~ ~s|aria-selected="true"|
      assert html =~ ~s|aria-selected="false"|

      # Product-filter select has an accessible name.
      assert html =~ ~s|aria-label="Filter by product"|
    end
  end

  describe "/dashboard/schedule" do
    test "has one <h1>, a <main> landmark, date-nav aria-labels, role=tablist view switcher",
         %{conn: conn} do
      {_view, html} = live_at(conn, ~p"/dashboard/schedule")

      assert count_matches(html, ~r|<h1\b|) == 1
      assert count_matches(html, ~r|<main\b|) == 1
      assert html =~ ~s|id="main-content"|
      assert html =~ ~s|aria-labelledby="page-title"|

      # Icon-only date navigation buttons have aria-labels.
      assert html =~ ~s|aria-label="Previous week"|
      assert html =~ ~s|aria-label="Next week"|
      assert html =~ ~s|aria-label="Jump to today"|

      # View switcher is a real tablist.
      assert html =~ ~s|aria-label="View mode"|
      assert html =~ ~s|role="tab"|
      assert html =~ ~s|aria-selected="true"|

      # Product-filter select has an accessible name.
      assert html =~ ~s|aria-label="Filter by product"|
    end
  end
end
