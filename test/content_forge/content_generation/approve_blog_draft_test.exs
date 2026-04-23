defmodule ContentForge.ContentGeneration.ApproveBlogDraftTest do
  @moduledoc """
  Coverage for the Phase 12.4 publish gate + override path on
  `ContentGeneration.approve_blog_draft/2` and
  `ContentGeneration.approve_blog_draft_with_override/3`.
  """
  use ContentForge.DataCase, async: false

  alias ContentForge.ContentGeneration
  alias ContentForge.ContentGeneration.Draft
  alias ContentForge.Products
  alias ContentForge.Repo

  setup do
    {:ok, product} =
      Products.create_product(%{name: "Gate Product", voice_profile: "professional"})

    %{product: product}
  end

  describe "approve_blog_draft/2 - gate pass" do
    test "approves a blog draft at or above the publish threshold", %{product: product} do
      draft = insert_blog_draft_with(product, seo_score: 25, research_status: "enriched")

      assert {:ok, %Draft{status: "approved", approved_via_override: false}} =
               ContentGeneration.approve_blog_draft(draft)
    end

    test "honors an override :publish_threshold option", %{product: product} do
      draft = insert_blog_draft_with(product, seo_score: 12)

      assert {:ok, %Draft{status: "approved"}} =
               ContentGeneration.approve_blog_draft(draft, publish_threshold: 10)
    end
  end

  describe "approve_blog_draft/2 - gate block" do
    test "returns :seo_below_threshold with failing_checks when below", %{product: product} do
      draft = insert_blog_draft_with(product, seo_score: 15)

      assert {:error, :seo_below_threshold, details} =
               ContentGeneration.approve_blog_draft(draft)

      assert details.score == 15
      assert details.threshold == 18
      assert is_list(details.failing_checks)
    end

    test "returns :research_lost_data when enricher flagged the draft", %{product: product} do
      draft =
        insert_blog_draft_with(product,
          seo_score: 25,
          research_status: "lost_data_point",
          research_source: "scoreboard"
        )

      assert {:error, :research_lost_data, %{research_source: "scoreboard"}} =
               ContentGeneration.approve_blog_draft(draft)
    end
  end

  describe "approve_blog_draft/2 - non-blog bypass" do
    test "non-blog drafts approve without gate checks", %{product: product} do
      {:ok, draft} =
        ContentGeneration.create_draft(%{
          product_id: product.id,
          content: "tweet body",
          platform: "twitter",
          content_type: "post",
          generating_model: "test"
        })

      assert {:ok, %Draft{status: "approved"}} =
               ContentGeneration.approve_blog_draft(draft)
    end
  end

  describe "approve_blog_draft_with_override/3" do
    test "records all four override fields when reason is long enough",
         %{product: product} do
      draft = insert_blog_draft_with(product, seo_score: 15, research_status: "no_data")
      reason = "human editor confirmed the draft is still publishable despite score"

      assert {:ok, %Draft{} = approved} =
               ContentGeneration.approve_blog_draft_with_override(draft, reason)

      assert approved.status == "approved"
      assert approved.approved_via_override == true
      assert approved.override_reason == reason
      assert approved.override_score_at_approval == 15
      assert approved.override_research_status_at_approval == "no_data"
    end

    test "rejects reasons under 20 chars", %{product: product} do
      draft = insert_blog_draft_with(product, seo_score: 15)

      assert {:error, :override_reason_too_short, %{min_length: 20, got_length: got}} =
               ContentGeneration.approve_blog_draft_with_override(draft, "too short")

      assert got < 20
    end

    test "trims whitespace before length check", %{product: product} do
      draft = insert_blog_draft_with(product, seo_score: 15)
      padded = "   " <> String.duplicate("x", 5) <> "   "

      assert {:error, :override_reason_too_short, _} =
               ContentGeneration.approve_blog_draft_with_override(draft, padded)
    end
  end

  # ---------------------------------------------------------------------------

  defp insert_blog_draft_with(product, attrs) do
    {:ok, draft} =
      ContentGeneration.create_draft(%{
        "product_id" => product.id,
        "content" => "# Blog Draft Title\n\nBody paragraph.",
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
