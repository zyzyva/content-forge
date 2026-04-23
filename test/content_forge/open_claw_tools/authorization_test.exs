defmodule ContentForge.OpenClawTools.AuthorizationTest do
  @moduledoc """
  Phase 16.3a: `Authorization.require(ctx, required_role)` is the
  single gate every light-write (16.3+) and heavy-write (16.4)
  tool calls before touching any data. These tests lock in the
  two-path resolver (SMS via ProductPhone, non-SMS via
  OperatorIdentity), the strict owner > submitter > viewer
  hierarchy, and the fail-closed catch-alls that keep missing
  config / unknown channels from granting access.
  """
  use ContentForge.DataCase, async: false

  alias ContentForge.OpenClawTools.Authorization
  alias ContentForge.Operators
  alias ContentForge.Products
  alias ContentForge.Sms

  setup do
    {:ok, product} =
      Products.create_product(%{name: "Gateland", voice_profile: "warm"})

    %{product: product}
  end

  defp sms_ctx(phone, product), do: %{channel: "sms", sender_identity: phone, product: product}

  defp cli_ctx(identity, product),
    do: %{channel: "cli", sender_identity: identity, product: product}

  defp register_phone(product, phone, role) do
    {:ok, _} =
      Sms.create_phone(%{
        product_id: product.id,
        phone_number: phone,
        role: role,
        active: true
      })
  end

  defp register_operator(product, identity, role, opts \\ []) do
    {:ok, row} =
      Operators.create_identity(%{
        product_id: product.id,
        identity: identity,
        role: role
      })

    if Keyword.get(opts, :deactivate, false) do
      {:ok, row} = Operators.deactivate_identity(row)
      row
    else
      row
    end
  end

  describe "hierarchy" do
    test "owner satisfies any required role", %{product: product} do
      register_phone(product, "+15551110001", "owner")
      ctx = sms_ctx("+15551110001", product)

      assert :ok = Authorization.require(ctx, :viewer)
      assert :ok = Authorization.require(ctx, :submitter)
      assert :ok = Authorization.require(ctx, :owner)
    end

    test "submitter satisfies submitter and viewer but not owner", %{product: product} do
      register_phone(product, "+15551110002", "submitter")
      ctx = sms_ctx("+15551110002", product)

      assert :ok = Authorization.require(ctx, :viewer)
      assert :ok = Authorization.require(ctx, :submitter)
      assert {:error, :forbidden} = Authorization.require(ctx, :owner)
    end

    test "viewer satisfies viewer only", %{product: product} do
      register_phone(product, "+15551110003", "viewer")
      ctx = sms_ctx("+15551110003", product)

      assert :ok = Authorization.require(ctx, :viewer)
      assert {:error, :forbidden} = Authorization.require(ctx, :submitter)
      assert {:error, :forbidden} = Authorization.require(ctx, :owner)
    end
  end

  describe "SMS channel resolver" do
    test "active ProductPhone with sufficient role returns :ok", %{product: product} do
      register_phone(product, "+15552220001", "submitter")

      assert :ok =
               Authorization.require(sms_ctx("+15552220001", product), :submitter)
    end

    test "insufficient role returns :forbidden", %{product: product} do
      register_phone(product, "+15552220002", "viewer")

      assert {:error, :forbidden} =
               Authorization.require(sms_ctx("+15552220002", product), :submitter)
    end

    test "inactive phone returns :forbidden", %{product: product} do
      {:ok, phone} =
        Sms.create_phone(%{
          product_id: product.id,
          phone_number: "+15552220003",
          role: "owner",
          active: false
        })

      assert phone.active == false

      assert {:error, :forbidden} =
               Authorization.require(sms_ctx("+15552220003", product), :viewer)
    end

    test "unknown phone returns :forbidden", %{product: product} do
      assert {:error, :forbidden} =
               Authorization.require(sms_ctx("+15559999999", product), :viewer)
    end

    test "phone registered for a different product returns :forbidden",
         %{product: product} do
      {:ok, other} = Products.create_product(%{name: "Elsewhere", voice_profile: "warm"})
      register_phone(other, "+15552220004", "owner")

      assert {:error, :forbidden} =
               Authorization.require(sms_ctx("+15552220004", product), :viewer)
    end
  end

  describe "CLI (non-phone) channel resolver" do
    test "active OperatorIdentity with sufficient role returns :ok", %{product: product} do
      register_operator(product, "cli:owner", "owner")

      assert :ok =
               Authorization.require(cli_ctx("cli:owner", product), :submitter)
    end

    test "insufficient role returns :forbidden", %{product: product} do
      register_operator(product, "cli:viewer", "viewer")

      assert {:error, :forbidden} =
               Authorization.require(cli_ctx("cli:viewer", product), :submitter)
    end

    test "missing identity returns :forbidden", %{product: product} do
      assert {:error, :forbidden} =
               Authorization.require(cli_ctx("cli:nobody", product), :viewer)
    end

    test "inactive identity returns :forbidden", %{product: product} do
      register_operator(product, "cli:retired", "owner", deactivate: true)

      assert {:error, :forbidden} =
               Authorization.require(cli_ctx("cli:retired", product), :viewer)
    end

    test "identity registered under a different product returns :forbidden",
         %{product: product} do
      {:ok, other} = Products.create_product(%{name: "Otherland", voice_profile: "warm"})
      register_operator(other, "cli:cross", "owner")

      assert {:error, :forbidden} =
               Authorization.require(cli_ctx("cli:cross", product), :viewer)
    end
  end

  describe "fail-closed invariants" do
    test "unknown channel returns :forbidden without hitting the DB",
         %{product: product} do
      ctx = %{channel: "telegram", sender_identity: "tg:me", product: product}
      assert {:error, :forbidden} = Authorization.require(ctx, :viewer)
    end

    test "missing channel key returns :forbidden", %{product: product} do
      ctx = %{sender_identity: "cli:me", product: product}
      assert {:error, :forbidden} = Authorization.require(ctx, :viewer)
    end

    test "nil sender_identity returns :forbidden", %{product: product} do
      ctx = %{channel: "sms", sender_identity: nil, product: product}
      assert {:error, :forbidden} = Authorization.require(ctx, :viewer)
    end

    test "empty sender_identity returns :forbidden", %{product: product} do
      ctx = %{channel: "cli", sender_identity: "", product: product}
      assert {:error, :forbidden} = Authorization.require(ctx, :viewer)
    end

    test "missing product returns :forbidden" do
      ctx = %{channel: "sms", sender_identity: "+15550000001", product: nil}
      assert {:error, :forbidden} = Authorization.require(ctx, :viewer)
    end

    test "missing product key returns :forbidden" do
      ctx = %{channel: "sms", sender_identity: "+15550000002"}
      assert {:error, :forbidden} = Authorization.require(ctx, :viewer)
    end

    test "unknown required role atom returns :forbidden", %{product: product} do
      register_phone(product, "+15550000003", "owner")

      assert {:error, :forbidden} =
               Authorization.require(sms_ctx("+15550000003", product), :superuser)
    end
  end
end
