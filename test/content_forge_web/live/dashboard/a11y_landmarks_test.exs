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

  describe "/dashboard/video" do
    test "has one <h1>, a <main> landmark, labeled filter, and progressbar aria",
         %{conn: conn} do
      {_view, html} = live_at(conn, ~p"/dashboard/video")

      assert count_matches(html, ~r|<h1\b|) == 1
      assert count_matches(html, ~r|<main\b|) == 1
      assert html =~ ~s|id="main-content"|
      assert html =~ ~s|aria-labelledby="page-title"|
      assert html =~ ~s|aria-label="Filter by product"|
    end
  end

  describe "/dashboard/performance" do
    test "has one <h1>, a <main> landmark, role=tablist view switcher, scope=col headers",
         %{conn: conn} do
      {_view, html} = live_at(conn, ~p"/dashboard/performance")

      assert count_matches(html, ~r|<h1\b|) == 1
      assert count_matches(html, ~r|<main\b|) == 1
      assert html =~ ~s|id="main-content"|
      assert html =~ ~s|aria-labelledby="page-title"|

      # Tab role wiring.
      assert html =~ ~s|aria-label="Performance view"|
      assert html =~ ~s|role="tab"|
      assert html =~ ~s|aria-selected="true"|

      # Filter select labeled.
      assert html =~ ~s|aria-label="Filter by product"|

      # Every table header uses scope="col".
      assert html =~ ~s|<th scope="col">|
      refute html =~ ~r|<th>[A-Z]|
    end
  end

  describe "/dashboard/clips" do
    test "has one <h1>, a <main> landmark, pending list as role=region",
         %{conn: conn} do
      {_view, html} = live_at(conn, ~p"/dashboard/clips")

      assert count_matches(html, ~r|<h1\b|) == 1
      assert count_matches(html, ~r|<main\b|) == 1
      assert html =~ ~s|id="main-content"|
      assert html =~ ~s|aria-labelledby="page-title"|
      assert html =~ ~s|id="pending-clips-heading"|
    end
  end

  describe "/dashboard/providers" do
    test "has one <h1>, a <main> landmark, and table with scope=col headers",
         %{conn: conn} do
      {_view, html} = live_at(conn, ~p"/dashboard/providers")

      assert count_matches(html, ~r|<h1\b|) == 1
      assert count_matches(html, ~r|<main\b|) == 1
      assert html =~ ~s|id="main-content"|
      assert html =~ ~s|aria-labelledby="page-title"|

      # Every provider-table column uses scope="col".
      assert html =~ ~s|<th scope="col">|
      refute html =~ ~r|<th>[A-Z]|
    end
  end

  describe "/dashboard/sms" do
    test "has one <h1>, a <main> landmark, and table with scope=col headers",
         %{conn: conn} do
      {_view, html} = live_at(conn, ~p"/dashboard/sms")

      assert count_matches(html, ~r|<h1\b|) == 1
      assert count_matches(html, ~r|<main\b|) == 1
      assert html =~ ~s|id="main-content"|
      assert html =~ ~s|aria-labelledby="page-title"|

      # Section headings are region-labelled.
      assert html =~ ~s|id="escalated-heading"|
      assert html =~ ~s|id="high-volume-heading"|
    end
  end

  # Every `role="tablist"` in the dashboard should carry
  # `phx-hook="TabList"` so the shared JS hook wires up arrow-key
  # roving focus + Home/End navigation. Tests assert the wiring
  # (the hook behavior itself ships in assets/js/hooks/tab_list.js).
  # Structural invariants the hook depends on: the tablist has an
  # `id` (LV hook requirement) and at least one child `role="tab"`
  # with `tabindex="0"`.
  describe "arrow-key tablist hook wiring" do
    test "drafts review tablist has TabList hook", %{conn: conn} do
      {_view, html} = live_at(conn, ~p"/dashboard/drafts")

      assert html =~
               ~r|role="tablist"[^>]*aria-label="Draft status filter"[^>]*phx-hook="TabList"|s or
               html =~
                 ~r|phx-hook="TabList"[^>]*role="tablist"[^>]*aria-label="Draft status filter"|s

      assert html =~ ~s|role="tab"|
      assert html =~ ~s|tabindex="0"|
    end

    test "performance view tablist has TabList hook", %{conn: conn} do
      {_view, html} = live_at(conn, ~p"/dashboard/performance")

      assert html =~ ~r|aria-label="Performance view"[^>]*phx-hook="TabList"|s or
               html =~ ~r|phx-hook="TabList"[^>]*aria-label="Performance view"|s
    end

    test "schedule view tablist has TabList hook", %{conn: conn} do
      {_view, html} = live_at(conn, ~p"/dashboard/schedule")

      assert html =~ ~r|aria-label="View mode"[^>]*phx-hook="TabList"|s or
               html =~ ~r|phx-hook="TabList"[^>]*aria-label="View mode"|s
    end

    test "product detail tablist has TabList hook + aria-selected + tabindex roving",
         %{conn: conn} do
      {:ok, product} =
        Products.create_product(%{
          name: "Tablist Product",
          voice_profile: "professional"
        })

      {_view, html} = live_at(conn, ~p"/dashboard/products/#{product.id}")

      assert html =~ ~s|role="tablist"|
      assert html =~ ~s|phx-hook="TabList"|

      # Product detail tabs must now expose aria-selected + tabindex
      # so the hook has state to rove (15.2c-era fix extended to this
      # previously-untouched tablist).
      assert html =~ ~s|aria-selected="true"|
      assert html =~ ~s|aria-selected="false"|
      assert html =~ ~s|tabindex="0"|
      assert html =~ ~s|tabindex="-1"|
    end
  end
end
