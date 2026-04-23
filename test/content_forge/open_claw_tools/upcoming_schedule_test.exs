defmodule ContentForge.OpenClawTools.UpcomingScheduleTest do
  @moduledoc """
  Phase 16.2 read-only tool: lists approved drafts awaiting publish
  (Content Forge does not hold per-draft schedule timestamps yet).
  """
  use ContentForge.DataCase, async: false

  alias ContentForge.ContentGeneration.Draft
  alias ContentForge.OpenClawTools.UpcomingSchedule
  alias ContentForge.Products
  alias ContentForge.Repo

  setup do
    {:ok, product} =
      Products.create_product(%{name: "Queueland", voice_profile: "warm"})

    %{product: product}
  end

  defp insert_draft(product, attrs) do
    base = %{
      product_id: product.id,
      content: String.duplicate("Body. ", 40),
      platform: "twitter",
      content_type: "post",
      generating_model: "stub",
      status: "approved"
    }

    {:ok, draft} =
      %Draft{}
      |> Draft.changeset(Map.merge(base, attrs))
      |> Repo.insert()

    draft
  end

  describe "call/2" do
    test "returns approved drafts with a short snippet and ISO-8601 timestamps",
         %{product: product} do
      draft = insert_draft(product, %{angle: "how_to", platform: "linkedin"})

      assert {:ok, result} =
               UpcomingSchedule.call(%{}, %{"product" => product.id})

      assert result.product_id == product.id
      assert result.product_name == "Queueland"
      assert result.count == 1

      [payload] = result.drafts
      assert payload.id == draft.id
      assert payload.platform == "linkedin"
      assert payload.angle == "how_to"
      assert payload.status == "approved"
      assert is_binary(payload.snippet)
      assert String.length(payload.snippet) <= 200
      assert is_binary(payload.approved_at)
    end

    test "filters by platform when supplied", %{product: product} do
      _twitter = insert_draft(product, %{platform: "twitter"})
      linkedin = insert_draft(product, %{platform: "linkedin"})

      {:ok, result} =
        UpcomingSchedule.call(%{}, %{"product" => product.id, "platform" => "linkedin"})

      assert result.count == 1
      assert [%{id: id}] = result.drafts
      assert id == linkedin.id
    end

    test "clamps limit between 1 and 25", %{product: product} do
      for i <- 1..3 do
        insert_draft(product, %{platform: "twitter", content: "body #{i}"})
      end

      {:ok, zero} = UpcomingSchedule.call(%{}, %{"product" => product.id, "limit" => 0})
      assert zero.count == 1

      {:ok, huge} = UpcomingSchedule.call(%{}, %{"product" => product.id, "limit" => 999})
      assert huge.count == 3
    end

    test "empty approved list returns count: 0 without an error", %{product: product} do
      assert {:ok, %{count: 0, drafts: []}} =
               UpcomingSchedule.call(%{}, %{"product" => product.id})
    end

    test "returns :missing_product_context when no product and no SMS session" do
      assert {:error, :missing_product_context} =
               UpcomingSchedule.call(%{channel: "cli", sender_identity: "cli:ops"}, %{})
    end
  end
end
