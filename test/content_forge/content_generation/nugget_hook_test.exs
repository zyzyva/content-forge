defmodule ContentForge.ContentGeneration.NuggetHookTest do
  @moduledoc """
  Integration coverage for the Phase 12.1 post-generation hook on
  blog drafts. When `ContentGeneration.create_draft/1` persists a
  `content_type: "blog"` draft, the nugget validator runs and:

    * on `:ok` populates `ai_summary_nugget` on the draft;
    * on `:error` flips `status` to `"needs_review"` and records
      the reasons on `error`.

  Non-blog drafts are unaffected.
  """
  use ContentForge.DataCase, async: true

  alias ContentForge.ContentGeneration
  alias ContentForge.Products

  @valid_nugget "Stripe: 2.9% + $0.30 per charge, 3-5 day payout, USD and EUR supported. Published Feb 2026 after the Checkout API rewrite that shipped January 15."

  setup do
    {:ok, product} =
      Products.create_product(%{name: "Nugget Product", voice_profile: "professional"})

    %{product: product}
  end

  describe "blog draft nugget hook" do
    test "populates ai_summary_nugget on a valid blog draft", %{product: product} do
      body = @valid_nugget <> "\n\nThe rest of the article."

      assert {:ok, draft} =
               ContentGeneration.create_draft(%{
                 "product_id" => product.id,
                 "content" => body,
                 "platform" => "blog",
                 "content_type" => "blog",
                 "generating_model" => "test"
               })

      assert draft.ai_summary_nugget == @valid_nugget
      assert draft.status == "draft"
      assert draft.error in [nil, ""]
    end

    test "flips a bad-nugget blog draft to needs_review with reasons on error",
         %{product: product} do
      bad_body =
        "This is why the system wins. It helps everyone. That is what counts. They love it."

      assert {:ok, draft} =
               ContentGeneration.create_draft(%{
                 "product_id" => product.id,
                 "content" => bad_body,
                 "platform" => "blog",
                 "content_type" => "blog",
                 "generating_model" => "test"
               })

      assert draft.status == "needs_review"
      assert is_binary(draft.error)

      assert draft.error =~ "too_short" or draft.error =~ "insufficient_entity_tokens" or
               draft.error =~ "outside_pronoun_reference"
    end

    test "non-blog drafts skip the hook entirely", %{product: product} do
      assert {:ok, draft} =
               ContentGeneration.create_draft(%{
                 "product_id" => product.id,
                 "content" => "short tweet",
                 "platform" => "twitter",
                 "content_type" => "post",
                 "generating_model" => "test"
               })

      assert draft.status == "draft"
      assert draft.ai_summary_nugget == nil
    end
  end
end
