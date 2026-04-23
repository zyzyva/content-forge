defmodule ContentForge.OpenClawTools.ProductResolverTest do
  @moduledoc """
  Phase 16.2 extracts product resolution out of CreateUploadLink
  so every OpenClaw tool shares the Feature 13 resolution
  contract: UUID / fuzzy-name / SMS session fallback.
  """
  use ContentForge.DataCase, async: false

  alias ContentForge.OpenClawTools.ProductResolver
  alias ContentForge.Products
  alias ContentForge.Sms

  describe "resolve/2 with explicit product param" do
    test "resolves by UUID when params carry a valid product id" do
      {:ok, product} =
        Products.create_product(%{name: "Nimbus Coffee", voice_profile: "warm"})

      assert {:ok, resolved} = ProductResolver.resolve(%{}, %{"product" => product.id})
      assert resolved.id == product.id
    end

    test "resolves by case-insensitive substring when params pass a name" do
      {:ok, product} =
        Products.create_product(%{name: "Acme Widgets Inc", voice_profile: "professional"})

      assert {:ok, resolved} = ProductResolver.resolve(%{}, %{"product" => "acme"})
      assert resolved.id == product.id
    end

    test "returns :product_not_found when neither UUID nor name matches" do
      assert {:error, :product_not_found} =
               ProductResolver.resolve(%{}, %{"product" => "ghostship"})
    end

    test "returns :ambiguous_product when two products share a name substring" do
      {:ok, _} = Products.create_product(%{name: "Ambiguous One", voice_profile: "warm"})
      {:ok, _} = Products.create_product(%{name: "Ambiguous Two", voice_profile: "warm"})

      assert {:error, :ambiguous_product} =
               ProductResolver.resolve(%{}, %{"product" => "ambiguous"})
    end

    test "treats an unknown UUID string like an unknown name" do
      {:ok, product} =
        Products.create_product(%{name: "Lone Sparrow", voice_profile: "warm"})

      random_uuid = Ecto.UUID.generate()

      assert {:error, :product_not_found} =
               ProductResolver.resolve(%{}, %{"product" => random_uuid})

      refute random_uuid == product.id
    end
  end

  describe "resolve/2 with missing product and SMS fallback" do
    test "resolves to the product when a single active ProductPhone matches the sender" do
      {:ok, product} =
        Products.create_product(%{name: "Phone Pilot", voice_profile: "warm"})

      {:ok, _} =
        Sms.create_phone(%{
          product_id: product.id,
          phone_number: "+15551234567",
          role: "owner",
          active: true
        })

      ctx = %{channel: "sms", sender_identity: "+15551234567"}
      assert {:ok, resolved} = ProductResolver.resolve(ctx, %{})
      assert resolved.id == product.id
    end

    test "returns :missing_product_context when no active phone matches" do
      ctx = %{channel: "sms", sender_identity: "+15559999999"}
      assert {:error, :missing_product_context} = ProductResolver.resolve(ctx, %{})
    end

    test "returns :missing_product_context when the matching phone is inactive" do
      {:ok, product} =
        Products.create_product(%{name: "Sleeping Pilot", voice_profile: "warm"})

      {:ok, _} =
        Sms.create_phone(%{
          product_id: product.id,
          phone_number: "+15558675309",
          role: "owner",
          active: false
        })

      ctx = %{channel: "sms", sender_identity: "+15558675309"}
      assert {:error, :missing_product_context} = ProductResolver.resolve(ctx, %{})
    end

    test "returns :missing_product_context when multiple active phones match the sender" do
      {:ok, product_a} =
        Products.create_product(%{name: "Twin Pilots A", voice_profile: "warm"})

      {:ok, product_b} =
        Products.create_product(%{name: "Twin Pilots B", voice_profile: "warm"})

      {:ok, _} =
        Sms.create_phone(%{
          product_id: product_a.id,
          phone_number: "+15557770001",
          role: "owner",
          active: true
        })

      {:ok, _} =
        Sms.create_phone(%{
          product_id: product_b.id,
          phone_number: "+15557770001",
          role: "owner",
          active: true
        })

      ctx = %{channel: "sms", sender_identity: "+15557770001"}
      assert {:error, :missing_product_context} = ProductResolver.resolve(ctx, %{})
    end

    test "returns :missing_product_context when channel is not sms and no product param supplied" do
      ctx = %{channel: "cli", sender_identity: "cli:ops"}
      assert {:error, :missing_product_context} = ProductResolver.resolve(ctx, %{})
    end

    test "returns :missing_product_context when the product param is an empty string and no session match" do
      ctx = %{channel: "sms", sender_identity: nil}

      assert {:error, :missing_product_context} =
               ProductResolver.resolve(ctx, %{"product" => ""})
    end
  end
end
