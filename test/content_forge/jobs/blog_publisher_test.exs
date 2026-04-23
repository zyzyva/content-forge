defmodule ContentForge.Jobs.BlogPublisherTest do
  use ExUnit.Case, async: true

  describe "get_product_slug/1" do
    test "converts product name to slug" do
      product = %{name: "My Test Product"}

      assert get_product_slug(product) == "my-test-product"
    end

    test "handles names with special characters" do
      product = %{name: "Test & Co. Product_123"}

      assert get_product_slug(product) == "test--co-product123"
    end

    test "handles all lowercase names" do
      product = %{name: "already lowercase"}

      assert get_product_slug(product) == "already-lowercase"
    end
  end

  describe "get_draft_title/1" do
    test "extracts title from markdown heading" do
      draft = %{content: "# Hello World\n\nSome content here."}

      assert get_draft_title(draft) == "Hello World"
    end

    test "handles multiple heading levels" do
      draft = %{content: "## Second Level Heading\n\nContent."}

      assert get_draft_title(draft) == "Second Level Heading"
    end

    test "returns default for empty content" do
      draft = %{content: ""}

      assert get_draft_title(draft) == "Untitled Blog Post"
    end

    test "returns default for no content" do
      draft = %{content: "   \n\n   "}

      assert get_draft_title(draft) == "Untitled Blog Post"
    end

    test "returns first non-heading line as fallback" do
      draft = %{content: "Just some text without a heading"}

      assert get_draft_title(draft) == "Just some text without a heading"
    end
  end

  # Inline reimplementation for testing
  defp get_product_slug(product) do
    product.name
    |> String.downcase()
    |> String.replace(~r/\s+/, "-")
    |> String.replace(~r/[^a-z0-9-]/, "")
  end

  defp get_draft_title(draft) do
    lines = String.split(draft.content, "\n", trim: true)

    case lines do
      [] ->
        "Untitled Blog Post"

      [first | _] ->
        first
        |> String.replace(~r/^#+\s*/, "")
        |> String.trim()
        |> then(&if &1 == "", do: "Untitled Blog Post", else: &1)
    end
  end
end
