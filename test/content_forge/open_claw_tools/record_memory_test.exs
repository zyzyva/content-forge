defmodule ContentForge.OpenClawTools.RecordMemoryTest do
  @moduledoc """
  Phase 16.3d: `record_memory` persists a conversation-derived
  note scoped to the resolved product. Gated by `:submitter`.
  The tool pulls `session_id`, `channel`, and `sender_identity`
  from the invocation ctx so the agent cannot spoof them via
  params.
  """
  use ContentForge.DataCase, async: false

  alias ContentForge.OpenClawTools.RecordMemory
  alias ContentForge.Products
  alias ContentForge.Sms

  setup do
    {:ok, product} =
      Products.create_product(%{name: "Recall Co", voice_profile: "warm"})

    %{product: product}
  end

  defp sms_ctx(phone, role, product, session_id \\ "sms-session-abc") do
    {:ok, _} =
      Sms.create_phone(%{
        product_id: product.id,
        phone_number: phone,
        role: role,
        active: true
      })

    %{
      channel: "sms",
      sender_identity: phone,
      session_id: session_id,
      product: product
    }
  end

  describe "call/2" do
    test "happy path writes a memory row from ctx + params", %{product: product} do
      ctx = sms_ctx("+15558880001", "submitter", product, "session-42")

      assert {:ok, result} =
               RecordMemory.call(ctx, %{
                 "product" => product.id,
                 "content" => "Client prefers matte finishes over glossy.",
                 "tags" => ["preference", "finish"]
               })

      assert is_binary(result.memory_id)
      assert result.product_id == product.id
      assert result.session_id == "session-42"
      assert is_binary(result.recorded_at)

      [persisted] = Products.list_recent_memories(product.id)
      assert persisted.id == result.memory_id
      assert persisted.channel == "sms"
      assert persisted.sender_identity == "+15558880001"
      assert persisted.content == "Client prefers matte finishes over glossy."
      assert persisted.tags == ["preference", "finish"]
    end

    test "trims + lowercases + dedupes tags before persisting", %{product: product} do
      ctx = sms_ctx("+15558880002", "submitter", product)

      {:ok, _} =
        RecordMemory.call(ctx, %{
          "product" => product.id,
          "content" => "A note",
          "tags" => [" Spring ", "SPRING", "summer"]
        })

      [row] = Products.list_recent_memories(product.id)
      assert row.tags == ["spring", "summer"]
    end

    test "viewer role = :forbidden without inserting", %{product: product} do
      ctx = sms_ctx("+15558880003", "viewer", product)

      assert {:error, :forbidden} =
               RecordMemory.call(ctx, %{
                 "product" => product.id,
                 "content" => "denied"
               })

      assert Products.list_recent_memories(product.id) == []
    end

    test "empty / whitespace content returns :empty_content", %{product: product} do
      ctx = sms_ctx("+15558880004", "submitter", product)

      assert {:error, :empty_content} =
               RecordMemory.call(ctx, %{"product" => product.id, "content" => "   "})

      assert {:error, :empty_content} =
               RecordMemory.call(ctx, %{"product" => product.id, "content" => ""})

      assert {:error, :empty_content} =
               RecordMemory.call(ctx, %{"product" => product.id})
    end

    test "content over 2000 chars returns :content_too_long", %{product: product} do
      ctx = sms_ctx("+15558880005", "submitter", product)

      long = String.duplicate("x", 2001)

      assert {:error, :content_too_long} =
               RecordMemory.call(ctx, %{"product" => product.id, "content" => long})
    end

    test "a tag over 40 chars returns :invalid_tag", %{product: product} do
      ctx = sms_ctx("+15558880006", "submitter", product)

      assert {:error, :invalid_tag} =
               RecordMemory.call(ctx, %{
                 "product" => product.id,
                 "content" => "ok",
                 "tags" => [String.duplicate("x", 41)]
               })
    end

    test "tags that are not strings return :invalid_tag", %{product: product} do
      ctx = sms_ctx("+15558880007", "submitter", product)

      assert {:error, :invalid_tag} =
               RecordMemory.call(ctx, %{
                 "product" => product.id,
                 "content" => "ok",
                 "tags" => [42, "spring"]
               })
    end

    test "missing session_id on ctx returns :missing_session", %{product: product} do
      ctx = sms_ctx("+15558880008", "submitter", product)
      ctx = Map.delete(ctx, :session_id)

      assert {:error, :missing_session} =
               RecordMemory.call(ctx, %{"product" => product.id, "content" => "ok"})
    end

    test "ambiguous product resolution returns :ambiguous_product before auth",
         %{product: _product} do
      {:ok, _} = Products.create_product(%{name: "Shared Memory Alpha", voice_profile: "warm"})
      {:ok, _} = Products.create_product(%{name: "Shared Memory Beta", voice_profile: "warm"})

      ctx = %{channel: "cli", sender_identity: "cli:unused", session_id: "s"}

      assert {:error, :ambiguous_product} =
               RecordMemory.call(ctx, %{"product" => "shared memory", "content" => "ok"})
    end
  end
end
