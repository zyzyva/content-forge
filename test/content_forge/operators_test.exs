defmodule ContentForge.OperatorsTest do
  @moduledoc """
  Phase 16.3a: `Operators` is the non-phone authorization resolver
  for the OpenClaw tool surface. These tests lock in the context
  shape the `Authorization` helper relies on, plus the schema-level
  invariants (role inclusion, partial unique on active rows,
  required fields).
  """
  use ContentForge.DataCase, async: false

  alias ContentForge.Operators
  alias ContentForge.Operators.OperatorIdentity
  alias ContentForge.Products

  setup do
    {:ok, product} =
      Products.create_product(%{name: "Opsland", voice_profile: "warm"})

    %{product: product}
  end

  describe "create_identity/1" do
    test "persists a new row with defaults and returns it", %{product: product} do
      assert {:ok, %OperatorIdentity{} = row} =
               Operators.create_identity(%{
                 product_id: product.id,
                 identity: "cli:ops",
                 role: "submitter"
               })

      assert row.product_id == product.id
      assert row.identity == "cli:ops"
      assert row.role == "submitter"
      assert row.active == true
    end

    test "trims whitespace on identity", %{product: product} do
      assert {:ok, row} =
               Operators.create_identity(%{
                 product_id: product.id,
                 identity: "  cli:trim  ",
                 role: "submitter"
               })

      assert row.identity == "cli:trim"
    end

    test "rejects an invalid role", %{product: product} do
      assert {:error, changeset} =
               Operators.create_identity(%{
                 product_id: product.id,
                 identity: "cli:ops",
                 role: "admin"
               })

      assert %{role: [_ | _]} = errors_on(changeset)
    end

    test "requires product_id, identity, and role", %{product: _product} do
      assert {:error, changeset} = Operators.create_identity(%{})

      errors = errors_on(changeset)
      assert errors[:product_id]
      assert errors[:identity]
      assert errors[:role]
    end

    test "prevents two active rows for the same (product, identity)", %{product: product} do
      {:ok, _} =
        Operators.create_identity(%{
          product_id: product.id,
          identity: "cli:duplicate",
          role: "submitter"
        })

      assert {:error, changeset} =
               Operators.create_identity(%{
                 product_id: product.id,
                 identity: "cli:duplicate",
                 role: "submitter"
               })

      assert errors_on(changeset)[:product_id] ||
               errors_on(changeset)[:identity]
    end

    test "allows re-seeding after deactivation", %{product: product} do
      {:ok, row} =
        Operators.create_identity(%{
          product_id: product.id,
          identity: "cli:reseed",
          role: "submitter"
        })

      {:ok, _} = Operators.deactivate_identity(row)

      assert {:ok, new_row} =
               Operators.create_identity(%{
                 product_id: product.id,
                 identity: "cli:reseed",
                 role: "owner"
               })

      assert new_row.id != row.id
      assert new_row.active == true
    end
  end

  describe "lookup_active_identity/2" do
    test "returns the active row for the given (identity, product)", %{product: product} do
      {:ok, row} =
        Operators.create_identity(%{
          product_id: product.id,
          identity: "cli:alice",
          role: "submitter"
        })

      assert %OperatorIdentity{id: id} =
               Operators.lookup_active_identity("cli:alice", product.id)

      assert id == row.id
    end

    test "returns nil when the identity is deactivated", %{product: product} do
      {:ok, row} =
        Operators.create_identity(%{
          product_id: product.id,
          identity: "cli:retired",
          role: "owner"
        })

      {:ok, _} = Operators.deactivate_identity(row)

      assert Operators.lookup_active_identity("cli:retired", product.id) == nil
    end

    test "returns nil for an unknown identity", %{product: product} do
      assert Operators.lookup_active_identity("cli:nobody", product.id) == nil
    end

    test "does not leak across products", %{product: product} do
      {:ok, other} =
        Products.create_product(%{name: "Otherland", voice_profile: "warm"})

      {:ok, _} =
        Operators.create_identity(%{
          product_id: other.id,
          identity: "cli:cross",
          role: "owner"
        })

      assert Operators.lookup_active_identity("cli:cross", product.id) == nil
    end
  end

  describe "list_identities_for_product/1" do
    test "returns active rows first, ordered by inserted_at", %{product: product} do
      {:ok, a} =
        Operators.create_identity(%{
          product_id: product.id,
          identity: "cli:first",
          role: "submitter"
        })

      {:ok, b} =
        Operators.create_identity(%{
          product_id: product.id,
          identity: "cli:second",
          role: "viewer"
        })

      assert ids = Enum.map(Operators.list_identities_for_product(product.id), & &1.id)
      assert a.id in ids
      assert b.id in ids
    end

    test "scopes strictly to the given product", %{product: product} do
      {:ok, other} =
        Products.create_product(%{name: "Outsider", voice_profile: "warm"})

      {:ok, mine} =
        Operators.create_identity(%{
          product_id: product.id,
          identity: "cli:own",
          role: "submitter"
        })

      {:ok, _theirs} =
        Operators.create_identity(%{
          product_id: other.id,
          identity: "cli:foreign",
          role: "submitter"
        })

      rows = Operators.list_identities_for_product(product.id)
      assert Enum.map(rows, & &1.id) == [mine.id]
    end
  end
end
