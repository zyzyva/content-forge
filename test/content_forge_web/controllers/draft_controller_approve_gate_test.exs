defmodule ContentForgeWeb.DraftControllerApproveGateTest do
  @moduledoc """
  Phase 12.4 publish-gate + override path coverage for the
  Review API's approve endpoints.
  """
  use ContentForgeWeb.ConnCase, async: true

  alias ContentForge.Accounts
  alias ContentForge.ContentGeneration
  alias ContentForge.ContentGeneration.Draft
  alias ContentForge.Products
  alias ContentForge.Repo

  @api_key String.duplicate("g", 48)

  setup %{conn: conn} do
    {:ok, _api_key} =
      Accounts.create_api_key(%{key: @api_key, label: "gate-test", active: true})

    {:ok, product} =
      Products.create_product(%{name: "Gate API Product", voice_profile: "professional"})

    authed =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{@api_key}")

    %{conn: authed, product: product}
  end

  describe "POST /api/v1/drafts/:id/approve" do
    test "approves a blog draft that passes the gate", %{conn: conn, product: product} do
      draft = insert_blog_draft_with(product, seo_score: 25, research_status: "enriched")

      conn = post(conn, ~p"/api/v1/drafts/#{draft.id}/approve", %{})
      assert %{"data" => %{"status" => "approved"}} = json_response(conn, 200)
    end

    test "returns 422 with failing_checks when blog seo_score is below threshold",
         %{conn: conn, product: product} do
      draft = insert_blog_draft_with(product, seo_score: 15)

      conn = post(conn, ~p"/api/v1/drafts/#{draft.id}/approve", %{})

      assert %{
               "error" => "seo_below_threshold",
               "score" => 15,
               "threshold" => 18,
               "failing_checks" => checks
             } = json_response(conn, 422)

      assert is_list(checks)
    end

    test "returns 422 with research_lost_data when enricher flagged the draft",
         %{conn: conn, product: product} do
      draft =
        insert_blog_draft_with(product,
          seo_score: 25,
          research_status: "lost_data_point",
          research_source: "scoreboard"
        )

      conn = post(conn, ~p"/api/v1/drafts/#{draft.id}/approve", %{})

      assert %{"error" => "research_lost_data", "research_source" => "scoreboard"} =
               json_response(conn, 422)
    end

    test "non-blog drafts bypass the gate and approve normally",
         %{conn: conn, product: product} do
      {:ok, draft} =
        ContentGeneration.create_draft(%{
          product_id: product.id,
          content: "tweet body",
          platform: "twitter",
          content_type: "post",
          generating_model: "test"
        })

      conn = post(conn, ~p"/api/v1/drafts/#{draft.id}/approve", %{})
      assert %{"data" => %{"status" => "approved"}} = json_response(conn, 200)
    end
  end

  describe "POST /api/v1/drafts/:id/approve_override" do
    test "records override fields and transitions to approved",
         %{conn: conn, product: product} do
      draft = insert_blog_draft_with(product, seo_score: 15, research_status: "no_data")
      reason = "human editor signed off manually for this weekly release"

      conn =
        post(conn, ~p"/api/v1/drafts/#{draft.id}/approve_override", %{"reason" => reason})

      assert %{"data" => %{"status" => "approved"}} = json_response(conn, 200)

      approved = ContentGeneration.get_draft!(draft.id)
      assert approved.approved_via_override == true
      assert approved.override_reason == reason
      assert approved.override_score_at_approval == 15
      assert approved.override_research_status_at_approval == "no_data"
    end

    test "returns 422 when reason is too short",
         %{conn: conn, product: product} do
      draft = insert_blog_draft_with(product, seo_score: 15)

      conn =
        post(conn, ~p"/api/v1/drafts/#{draft.id}/approve_override", %{"reason" => "short"})

      assert %{
               "error" => "override_reason_too_short",
               "min_length" => 20
             } = json_response(conn, 422)
    end
  end

  defp insert_blog_draft_with(product, attrs) do
    {:ok, draft} =
      ContentGeneration.create_draft(%{
        "product_id" => product.id,
        "content" => "# Blog Draft\n\nBody.",
        "platform" => "blog",
        "content_type" => "blog",
        "generating_model" => "test"
      })

    draft
    |> Draft.changeset(Enum.into(attrs, %{}))
    |> Repo.update!()
    |> Repo.reload!()
  end
end
