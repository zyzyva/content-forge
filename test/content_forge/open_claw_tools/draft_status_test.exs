defmodule ContentForge.OpenClawTools.DraftStatusTest do
  @moduledoc """
  Phase 16.2 read-only tool: returns a draft's current status
  (either by explicit `draft_id` or by a case-insensitive `hint`
  matched against content / angle within the resolved product
  scope).
  """
  use ContentForge.DataCase, async: false

  alias ContentForge.ContentGeneration.Draft
  alias ContentForge.OpenClawTools.DraftStatus
  alias ContentForge.Products
  alias ContentForge.Repo

  setup do
    {:ok, product} =
      Products.create_product(%{name: "Draftland", voice_profile: "warm"})

    %{product: product}
  end

  defp insert_draft(product, attrs) do
    base = %{
      product_id: product.id,
      content: "Body text",
      platform: "twitter",
      content_type: "post",
      generating_model: "stub-model",
      status: "draft"
    }

    {:ok, draft} =
      %Draft{}
      |> Draft.changeset(Map.merge(base, attrs))
      |> Repo.insert()

    draft
  end

  describe "call/2 via draft_id" do
    test "returns the full status payload for a draft owned by the product", %{product: product} do
      draft =
        insert_draft(product, %{
          content: "Full kitchen remodel post",
          platform: "blog",
          content_type: "blog",
          angle: "case_study",
          status: "ranked",
          generating_model: "stub-claude"
        })

      assert {:ok, result} =
               DraftStatus.call(%{}, %{"draft_id" => draft.id, "product" => product.id})

      assert result.draft_id == draft.id
      assert result.product_id == product.id
      assert result.product_name == "Draftland"
      assert result.platform == "blog"
      assert result.content_type == "blog"
      assert result.angle == "case_study"
      assert result.status == "ranked"
      assert result.generating_model == "stub-claude"
      assert result.approval_required == true
      assert result.blocker == nil
      assert is_binary(result.updated_at)
    end

    test "approval_required is false for non-blog platforms", %{product: product} do
      draft = insert_draft(product, %{platform: "twitter", content_type: "post"})

      assert {:ok, %{approval_required: false}} =
               DraftStatus.call(%{}, %{"draft_id" => draft.id, "product" => product.id})
    end

    test "approval_required is false once a blog draft is approved", %{product: product} do
      draft =
        insert_draft(product, %{platform: "blog", content_type: "blog", status: "approved"})

      assert {:ok, %{approval_required: false, approved_at: approved_at}} =
               DraftStatus.call(%{}, %{"draft_id" => draft.id, "product" => product.id})

      assert is_binary(approved_at)
    end

    test "blocker surfaces the draft's error string when status is blocked",
         %{product: product} do
      draft =
        insert_draft(product, %{
          platform: "blog",
          content_type: "blog",
          status: "blocked",
          content: "stuck"
        })

      {:ok, draft} =
        draft
        |> Draft.changeset(%{error: "awaiting image"})
        |> Repo.update()

      assert {:ok, %{blocker: "awaiting image", status: "blocked"}} =
               DraftStatus.call(%{}, %{"draft_id" => draft.id, "product" => product.id})
    end

    test "returns :not_found when the draft belongs to a different product",
         %{product: product} do
      {:ok, other} =
        Products.create_product(%{name: "Otherland", voice_profile: "warm"})

      draft = insert_draft(other, %{})

      assert {:error, :not_found} =
               DraftStatus.call(%{}, %{"draft_id" => draft.id, "product" => product.id})
    end

    test "returns :not_found when the draft id is a well-formed UUID with no row",
         %{product: product} do
      assert {:error, :not_found} =
               DraftStatus.call(%{}, %{
                 "draft_id" => Ecto.UUID.generate(),
                 "product" => product.id
               })
    end
  end

  describe "call/2 via hint" do
    test "finds a single draft by case-insensitive content match", %{product: product} do
      draft =
        insert_draft(product, %{content: "Johnson Kitchen remodel post draft"})

      assert {:ok, %{draft_id: id}} =
               DraftStatus.call(%{}, %{"product" => product.id, "hint" => "johnson kitchen"})

      assert id == draft.id
    end

    test "returns :ambiguous_draft when the hint matches multiple drafts", %{product: product} do
      draft_a = insert_draft(product, %{content: "Spring promo kitchen"})
      draft_b = insert_draft(product, %{content: "Kitchen remodel winter edit"})

      assert {:error, {:ambiguous_draft, %{candidates: candidates}}} =
               DraftStatus.call(%{}, %{"product" => product.id, "hint" => "kitchen"})

      ids = Enum.map(candidates, & &1.id)
      assert draft_a.id in ids
      assert draft_b.id in ids
      assert length(candidates) <= 3
      assert Enum.all?(candidates, &is_binary(&1.snippet))
    end

    test "returns :not_found when neither content nor angle matches the hint",
         %{product: product} do
      insert_draft(product, %{content: "unrelated"})

      assert {:error, :not_found} =
               DraftStatus.call(%{}, %{"product" => product.id, "hint" => "mystery"})
    end

    test "scopes the hint search to the resolved product", %{product: product} do
      {:ok, other_product} =
        Products.create_product(%{name: "Elsewhere", voice_profile: "warm"})

      insert_draft(other_product, %{content: "kitchen remodel elsewhere"})

      assert {:error, :not_found} =
               DraftStatus.call(%{}, %{"product" => product.id, "hint" => "kitchen remodel"})
    end
  end

  describe "call/2 with no identifier" do
    test "returns :not_found when neither draft_id nor hint is supplied",
         %{product: product} do
      assert {:error, :not_found} =
               DraftStatus.call(%{}, %{"product" => product.id})
    end
  end
end
