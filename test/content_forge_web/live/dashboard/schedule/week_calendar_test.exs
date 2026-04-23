defmodule ContentForgeWeb.Live.Dashboard.Schedule.WeekCalendarTest do
  use ContentForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog

  alias ContentForge.ContentGeneration
  alias ContentForge.Products
  alias ContentForge.Publishing

  defp create_product! do
    {:ok, product} = Products.create_product(%{name: "P", voice_profile: "professional"})
    product
  end

  defp create_draft!(product, attrs \\ %{}) do
    defaults = %{
      product_id: product.id,
      content: "draft body",
      platform: "twitter",
      content_type: "post",
      generating_model: "claude",
      status: "approved",
      image_url: "https://cdn/img.png"
    }

    {:ok, draft} = ContentGeneration.create_draft(Map.merge(defaults, attrs))
    draft
  end

  defp create_published!(product, draft, posted_at, platform) do
    {:ok, post} =
      Publishing.create_published_post(%{
        product_id: product.id,
        draft_id: draft.id,
        platform: platform,
        platform_post_id: "PP_#{System.unique_integer([:positive])}",
        platform_post_url: "https://example.com/p/1",
        posted_at: posted_at
      })

    post
  end

  describe "week view" do
    test "renders 7 day cells with day headers", %{conn: conn} do
      capture_log(fn ->
        result = live(conn, ~p"/dashboard/schedule?view=calendar")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, _view, html}}

      # 7 day cells with data-week-day attribute — in each layout
      # (desktop grid + mobile stack), giving 14 total.
      week_day_matches = Regex.scan(~r/data-week-day="([^"]+)"/, html)
      assert length(week_day_matches) == 14

      iso_days = week_day_matches |> Enum.map(fn [_, iso] -> iso end) |> Enum.uniq()
      assert length(iso_days) == 7

      # Day-of-week headers - we pick a couple to assert.
      assert html =~ "Sun" or html =~ "Mon"
    end

    test "published posts appear in their own day column with platform badge",
         %{conn: conn} do
      product = create_product!()
      draft = create_draft!(product, %{content: "tw post content"})

      today_dt = DateTime.utc_now()
      _post = create_published!(product, draft, today_dt, "twitter")

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/schedule?view=calendar")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, _view, html}}

      today_str = Date.to_iso8601(Date.utc_today())
      assert html =~ ~s|data-week-day="#{today_str}"|
      # An entry card for the post renders with platform label.
      assert html =~ "twitter"
      # Draft snippet surfaces in the cell.
      assert html =~ "tw post content"
    end

    test "approved drafts appear in today's column as 'upcoming'",
         %{conn: conn} do
      product = create_product!()
      _draft = create_draft!(product, %{content: "approved but not yet published"})

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/schedule?view=calendar")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, _view, html}}

      today_str = Date.to_iso8601(Date.utc_today())
      assert html =~ ~s|data-week-day="#{today_str}"|
      assert html =~ "approved but not yet published"
    end
  end

  describe "click -> draft preview" do
    test "preview_draft event opens drawer with full content", %{conn: conn} do
      product = create_product!()

      draft =
        create_draft!(product, %{
          content: "body of the draft to preview in full",
          platform: "linkedin"
        })

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/schedule?view=calendar")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}

      html = render_click(view, "preview_draft", %{"draft-id" => draft.id})

      assert html =~ ~s|data-draft-preview|
      assert html =~ "body of the draft to preview in full"
      assert html =~ "linkedin"
    end

    test "close_preview event clears the drawer", %{conn: conn} do
      product = create_product!()
      draft = create_draft!(product, %{content: "closeable"})

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/schedule?view=calendar")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}

      _ = render_click(view, "preview_draft", %{"draft-id" => draft.id})
      html = render_click(view, "close_preview", %{})

      refute html =~ ~s|data-draft-preview|
    end
  end

  describe "mobile layout" do
    test "stacked daily list is present with md:hidden", %{conn: conn} do
      capture_log(fn ->
        result = live(conn, ~p"/dashboard/schedule?view=calendar")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, _view, html}}

      # The desktop grid is md:grid; the stacked list is the md:hidden
      # companion. Both must be present so each viewport lands on the
      # right layout without JS.
      assert html =~ "md:hidden"
      assert html =~ "md:grid"
      assert html =~ ~s|data-week-calendar-mobile|
    end
  end
end
