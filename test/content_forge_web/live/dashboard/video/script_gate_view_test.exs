defmodule ContentForgeWeb.Live.Dashboard.Video.ScriptGateViewTest do
  use ContentForgeWeb.ConnCase, async: false
  use Oban.Testing, repo: ContentForge.Repo

  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog

  alias ContentForge.ContentGeneration
  alias ContentForge.Products
  alias ContentForge.Publishing

  defp create_product! do
    {:ok, product} =
      Products.create_product(%{name: "Gate Product", voice_profile: "professional"})

    product
  end

  defp create_script!(product, attrs \\ %{}) do
    defaults = %{
      product_id: product.id,
      content: "My video script content",
      platform: "youtube",
      content_type: "video_script",
      generating_model: "claude",
      status: "ranked"
    }

    {:ok, draft} = ContentGeneration.create_draft(Map.merge(defaults, attrs))
    draft
  end

  defp score!(draft, composite) do
    {:ok, _} =
      ContentGeneration.create_draft_score(%{
        draft_id: draft.id,
        model_name: "claude",
        accuracy_score: composite,
        seo_score: composite,
        eev_score: composite,
        composite_score: composite,
        critique: "t"
      })
  end

  describe "Script Gate section" do
    test "renders threshold + each candidate with composite score", %{conn: conn} do
      product = create_product!()
      above = create_script!(product, %{content: "above-the-bar script"})
      score!(above, 8.0)

      below = create_script!(product, %{content: "below-the-bar script"})
      score!(below, 3.0)

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/video")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, _view, html}}

      assert html =~ "Script Gate"
      assert html =~ ~s|data-script-gate-threshold|

      assert html =~ ~s|data-script-candidate="#{above.id}"|
      assert html =~ ~s|data-below-threshold="false"|
      assert html =~ "ABOVE"
      assert html =~ "8.00"

      assert html =~ ~s|data-script-candidate="#{below.id}"|
      assert html =~ ~s|data-below-threshold="true"|
      assert html =~ "BELOW"
      assert html =~ "Override promote"
    end

    test "unscored script renders as UNSCORED + Override promote", %{conn: conn} do
      product = create_product!()
      draft = create_script!(product)

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/video")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, _view, html}}

      assert html =~ ~s|data-script-candidate="#{draft.id}"|
      assert html =~ "UNSCORED"
      assert html =~ "Override promote"
    end

    test "renders empty state when no candidates are waiting", %{conn: conn} do
      capture_log(fn ->
        result = live(conn, ~p"/dashboard/video")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, _view, html}}

      assert html =~ "No ranked scripts awaiting the gate"
    end
  end

  describe "promote_script event" do
    test "above-threshold promote creates VideoJob with override=false + no OVERRIDE badge",
         %{conn: conn} do
      product = create_product!()
      draft = create_script!(product)
      score!(draft, 9.0)

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/video")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}

      html = render_click(view, "promote_script", %{"draft-id" => draft.id})

      job = Publishing.get_video_job_by_draft(draft.id)
      assert job.promoted_via_override == false
      assert job.promoted_score == 9.0

      refute html =~ ~s|data-promoted-override="#{job.id}"|

      # Draft is flipped approved, so it no longer appears as a candidate.
      refute html =~ ~s|data-script-candidate="#{draft.id}"|
    end

    test "below-threshold override creates VideoJob with override=true + OVERRIDE badge",
         %{conn: conn} do
      product = create_product!()
      draft = create_script!(product)
      score!(draft, 3.0)

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/video")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}

      html = render_click(view, "promote_script", %{"draft-id" => draft.id})

      job = Publishing.get_video_job_by_draft(draft.id)
      assert job.promoted_via_override == true
      assert job.promoted_score == 3.0
      assert job.promoted_threshold == Publishing.script_gate_threshold()

      # OVERRIDE badge rendered on the job card in the Jobs list.
      assert html =~ "OVERRIDE"
      assert html =~ ~s|data-promoted-override="#{job.id}"|
    end

    test "filters candidates by product_id when set", %{conn: conn} do
      product_a = create_product!()
      Process.sleep(1)
      {:ok, product_b} = Products.create_product(%{name: "B", voice_profile: "casual"})

      draft_a = create_script!(product_a)
      draft_b = create_script!(product_b)

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/video?product=#{product_a.id}")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, _view, html}}

      assert html =~ ~s|data-script-candidate="#{draft_a.id}"|
      refute html =~ ~s|data-script-candidate="#{draft_b.id}"|
    end
  end
end
