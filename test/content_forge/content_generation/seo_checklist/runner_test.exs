defmodule ContentForge.ContentGeneration.SeoChecklist.RunnerTest do
  @moduledoc """
  Integration tests for the Phase 12.2a SEO checklist runner.
  Asserts the dispatch surface (28 checks defined, each called
  once per run), the aggregate score math, and the upsert-by-
  draft-id contract.
  """
  use ContentForge.DataCase, async: true

  alias ContentForge.ContentGeneration
  alias ContentForge.ContentGeneration.SeoChecklist
  alias ContentForge.ContentGeneration.SeoChecklist.Runner
  alias ContentForge.Products
  alias ContentForge.Repo

  @good_content """
  # A Compact SEO-ready Title

  <meta name="description" content="A focused summary that stays under 155 characters and carries at least one entity name so search engines do not truncate it.">

  Stripe: 2.9% + $0.30 per charge, 3-5 day payout, USD and EUR supported. Published Feb 2026 after the Checkout API rewrite that shipped January 15.

  The rest of the blog article goes here and continues for many paragraphs explaining the topic.
  """

  setup do
    {:ok, product} =
      Products.create_product(%{name: "SEO Product", voice_profile: "professional"})

    {:ok, draft} =
      ContentGeneration.create_draft(%{
        "product_id" => product.id,
        "content" => @good_content,
        "platform" => "blog",
        "content_type" => "blog",
        "generating_model" => "test"
      })

    %{product: product, draft: Repo.reload(draft)}
  end

  describe "checks/0" do
    test "defines exactly 28 checks" do
      assert length(Runner.checks()) == 28
    end

    test "every check entry is a {name, module} tuple" do
      assert Enum.all?(Runner.checks(), fn
               {name, mod} when is_atom(name) and is_atom(mod) -> true
               _ -> false
             end)
    end
  end

  describe "run/1" do
    test "persists a SeoChecklist row keyed by draft_id with 28 result keys",
         %{draft: draft} do
      # The post-generation hook already ran in setup; fetch the row.
      assert checklist = Runner.get_for_draft(draft.id)
      assert %SeoChecklist{} = checklist
      assert map_size(checklist.results) == 28
      assert checklist.score >= 0
      assert checklist.run_at != nil
    end

    test "draft.seo_score mirrors the checklist aggregate score",
         %{draft: draft} do
      reloaded = Repo.reload(draft)
      checklist = Runner.get_for_draft(draft.id)
      assert reloaded.seo_score == checklist.score
    end

    test "upserts instead of creating a second row per draft",
         %{draft: draft} do
      assert {:ok, _} = Runner.run(draft)
      assert {:ok, _} = Runner.run(draft)

      rows = Repo.all(SeoChecklist)
      assert Enum.count(rows, &(&1.draft_id == draft.id)) == 1
    end

    test "each result has a status in pass/fail/not_applicable", %{draft: draft} do
      checklist = Runner.get_for_draft(draft.id)

      Enum.each(checklist.results, fn {_name, value} ->
        assert value["status"] in ["pass", "fail", "not_applicable"]
      end)
    end

    test "every check carries a non-stub note - all 28 implemented",
         %{draft: draft} do
      checklist = Runner.get_for_draft(draft.id)

      Enum.each(checklist.results, fn {name, value} ->
        refute value["note"] == "check not implemented yet",
               "expected #{name} to be implemented, got stub note"

        assert value["status"] in ["pass", "fail", "not_applicable"]
      end)
    end
  end
end
