defmodule ContentForge.ContentGenerationTest do
  use ContentForge.DataCase, async: true
  import ExUnit.CaptureLog

  alias ContentForge.ContentGeneration
  alias ContentForge.Products

  defp create_product do
    {:ok, product} =
      Products.create_product(%{
        name: "Test Product",
        voice_profile: "professional"
      })

    product
  end

  defp create_brief(product, attrs \\ %{}) do
    defaults = %{
      product_id: product.id,
      version: 1,
      content: "Initial brief content",
      model_used: "claude"
    }

    {:ok, brief} = ContentGeneration.create_content_brief(Map.merge(defaults, attrs))
    brief
  end

  describe "create_new_brief_version/4" do
    test "does not crash and treats nil version as 0, returning version 1" do
      product = create_product()
      brief = create_brief(product)

      # Simulate a brief struct with nil version (as can happen in practice when
      # a record is loaded from DB before constraints were enforced or populated
      # via a path that bypassed the changeset).
      nil_version_brief = %{brief | version: nil}
      assert nil_version_brief.version == nil

      capture_log(fn ->
        result =
          ContentGeneration.create_new_brief_version(
            nil_version_brief,
            "New content after nil version",
            %{},
            "test rewrite"
          )

        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, updated_brief}}
      # nil version is treated as 1 to satisfy archive constraint (> 0),
      # so new version = 1 + 1 = 2
      assert updated_brief.version == 2
    end

    test "increments version from 2 to 3" do
      product = create_product()
      brief = create_brief(product, %{version: 2})

      capture_log(fn ->
        result =
          ContentGeneration.create_new_brief_version(
            brief,
            "Updated content",
            %{clicks: 100},
            "performance rewrite"
          )

        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, updated_brief}}
      assert updated_brief.version == 3
    end

    test "archives the current version as a BriefVersion record" do
      product = create_product()
      brief = create_brief(product, %{version: 1, content: "Original content"})

      capture_log(fn ->
        result =
          ContentGeneration.create_new_brief_version(
            brief,
            "Replacement content",
            %{},
            "test archive"
          )

        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, _updated_brief}}

      versions = ContentGeneration.list_brief_versions_for_brief(brief.id)
      assert length(versions) == 1
      [archived] = versions
      assert archived.version == 1
      assert archived.content == "Original content"
    end

    test "updates the brief content to new_content" do
      product = create_product()
      brief = create_brief(product, %{version: 5, content: "Old content"})

      capture_log(fn ->
        result =
          ContentGeneration.create_new_brief_version(
            brief,
            "Brand new content",
            %{impressions: 500},
            nil
          )

        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, updated_brief}}
      assert updated_brief.content == "Brand new content"
      assert updated_brief.version == 6
    end
  end
end
