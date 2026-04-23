defmodule ContentForge.Products.ProductMemoryTest do
  @moduledoc """
  Phase 16.3d: schema-level invariants + context helpers for
  `ProductMemory`. Drives the invariants the `record_memory`
  tool relies on (content length, tag shape, ordering).
  """
  use ContentForge.DataCase, async: false

  alias ContentForge.Products
  alias ContentForge.Products.ProductMemory

  setup do
    {:ok, product} =
      Products.create_product(%{name: "Recall Co", voice_profile: "warm"})

    %{product: product}
  end

  defp memory_attrs(product, overrides \\ %{}) do
    Map.merge(
      %{
        product_id: product.id,
        session_id: "session-abc",
        channel: "sms",
        sender_identity: "+15557770000",
        content: "Client prefers matte finishes over glossy.",
        tags: ["preference"]
      },
      overrides
    )
  end

  describe "create_memory/1" do
    test "persists a row with the supplied attrs", %{product: product} do
      assert {:ok, %ProductMemory{} = memory} =
               Products.create_memory(memory_attrs(product))

      assert memory.product_id == product.id
      assert memory.session_id == "session-abc"
      assert memory.channel == "sms"
      assert memory.content =~ "matte finishes"
      assert memory.tags == ["preference"]
    end

    test "defaults tags to an empty list when omitted", %{product: product} do
      {:ok, memory} =
        Products.create_memory(memory_attrs(product, %{tags: nil}) |> Map.delete(:tags))

      assert memory.tags == []
    end

    test "requires product_id, session_id, channel, content", %{product: _product} do
      assert {:error, changeset} = Products.create_memory(%{})

      errors = errors_on(changeset)
      assert errors[:product_id]
      assert errors[:session_id]
      assert errors[:channel]
      assert errors[:content]
    end

    test "rejects empty content", %{product: product} do
      assert {:error, cs} =
               Products.create_memory(memory_attrs(product, %{content: ""}))

      assert errors_on(cs)[:content]
    end

    test "rejects content over 2000 chars", %{product: product} do
      long = String.duplicate("x", 2001)

      assert {:error, cs} =
               Products.create_memory(memory_attrs(product, %{content: long}))

      assert errors_on(cs)[:content]
    end

    test "rejects tags over 40 chars", %{product: product} do
      assert {:error, cs} =
               Products.create_memory(
                 memory_attrs(product, %{tags: [String.duplicate("y", 41)]})
               )

      assert errors_on(cs)[:tags]
    end
  end

  describe "list_recent_memories/2" do
    test "returns rows newest-first limited to `limit`", %{product: product} do
      {:ok, first} = Products.create_memory(memory_attrs(product, %{content: "first note"}))
      {:ok, second} = Products.create_memory(memory_attrs(product, %{content: "second note"}))
      {:ok, third} = Products.create_memory(memory_attrs(product, %{content: "third note"}))

      # Second-precision timestamps can tie; back-date the older rows so
      # the newest-first ordering is deterministic under the sandbox.
      back_date = fn memory, minutes ->
        memory
        |> Ecto.Changeset.change(
          inserted_at: DateTime.add(memory.inserted_at, -minutes * 60, :second)
        )
        |> ContentForge.Repo.update!()
      end

      back_date.(first, 2)
      back_date.(second, 1)

      rows = Products.list_recent_memories(product.id, 2)
      assert Enum.map(rows, & &1.id) == [third.id, second.id]
    end

    test "default limit is 10", %{product: product} do
      for i <- 1..12 do
        {:ok, _} =
          Products.create_memory(memory_attrs(product, %{content: "note #{i}"}))
      end

      assert length(Products.list_recent_memories(product.id)) == 10
    end

    test "scopes strictly to the given product", %{product: product} do
      {:ok, other} =
        Products.create_product(%{name: "Elsewhere", voice_profile: "warm"})

      {:ok, _} = Products.create_memory(memory_attrs(product))
      {:ok, _} = Products.create_memory(memory_attrs(other))

      mine = Products.list_recent_memories(product.id)
      assert length(mine) == 1
      assert hd(mine).product_id == product.id
    end
  end
end
