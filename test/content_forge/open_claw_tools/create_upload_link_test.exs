defmodule ContentForge.OpenClawTools.CreateUploadLinkTest do
  @moduledoc """
  Phase 16.3b hardens CreateUploadLink:

    * `Authorization.require(..., :submitter)` gates every
      invocation.
    * `AcceptedContentTypes.allowed?/1` refuses non-allow-list
      MIME types with `:unsupported_content_type` before the
      presign call.
    * `expires_in_seconds` is clamped to the configured ceiling
      (`:content_forge, :open_claw_tools,
      :max_upload_expires_seconds`, default 3600). Values at or
      below zero fall back to the default 900.

  Happy-path behavior around presign / storage-key / product
  resolution is exercised by the controller suite in
  `test/content_forge_web/controllers/open_claw_tool_controller_test.exs`;
  this file focuses on the new gates and their edge cases.
  """
  use ContentForge.DataCase, async: false

  alias ContentForge.OpenClawTools.CreateUploadLink
  alias ContentForge.Operators
  alias ContentForge.Products
  alias ContentForge.Sms

  defmodule StorageStub do
    @moduledoc false
    def presigned_put_url(storage_key, _content_type, _opts),
      do: {:ok, "https://stub.example/put/" <> storage_key}
  end

  setup do
    {:ok, product} =
      Products.create_product(%{name: "Gateland", voice_profile: "warm"})

    original_storage = Application.get_env(:content_forge, :asset_storage_impl)
    original_tools = Application.get_env(:content_forge, :open_claw_tools)

    Application.put_env(:content_forge, :asset_storage_impl, StorageStub)

    on_exit(fn ->
      restore_env(:asset_storage_impl, original_storage)
      restore_env(:open_claw_tools, original_tools)
    end)

    %{product: product}
  end

  defp restore_env(key, nil), do: Application.delete_env(:content_forge, key)
  defp restore_env(key, value), do: Application.put_env(:content_forge, key, value)

  defp sms_ctx(phone, role, product) do
    {:ok, _} =
      Sms.create_phone(%{
        product_id: product.id,
        phone_number: phone,
        role: role,
        active: true
      })

    %{channel: "sms", sender_identity: phone, product: product}
  end

  defp cli_ctx(identity, role, product) do
    {:ok, _} =
      Operators.create_identity(%{
        product_id: product.id,
        identity: identity,
        role: role
      })

    %{channel: "cli", sender_identity: identity}
  end

  describe "authorization" do
    test "viewer role on ProductPhone = :forbidden", %{product: product} do
      ctx = sms_ctx("+15552220001", "viewer", product)

      assert {:error, :forbidden} =
               CreateUploadLink.call(ctx, %{"product" => product.id})
    end

    test "submitter role on ProductPhone = :ok", %{product: product} do
      ctx = sms_ctx("+15552220002", "submitter", product)

      assert {:ok, %{product_id: pid}} =
               CreateUploadLink.call(ctx, %{"product" => product.id})

      assert pid == product.id
    end

    test "owner role on OperatorIdentity = :ok", %{product: product} do
      ctx = cli_ctx("cli:owner", "owner", product)

      assert {:ok, _} =
               CreateUploadLink.call(ctx, %{"product" => product.id})
    end

    test "CLI without an OperatorIdentity row = :forbidden", %{product: product} do
      ctx = %{channel: "cli", sender_identity: "cli:stranger"}

      assert {:error, :forbidden} =
               CreateUploadLink.call(ctx, %{"product" => product.id})
    end

    test "unknown channel = :forbidden", %{product: product} do
      ctx = %{channel: "telegram", sender_identity: "tg:someone"}

      assert {:error, :forbidden} =
               CreateUploadLink.call(ctx, %{"product" => product.id})
    end
  end

  describe "content-type allow-list" do
    test "rejects a non-allow-list type with :unsupported_content_type",
         %{product: product} do
      ctx = sms_ctx("+15552220010", "submitter", product)

      assert {:error, :unsupported_content_type} =
               CreateUploadLink.call(ctx, %{
                 "product" => product.id,
                 "content_type" => "application/x-malware"
               })
    end

    test "accepts an allow-listed image type", %{product: product} do
      ctx = sms_ctx("+15552220011", "submitter", product)

      assert {:ok, _} =
               CreateUploadLink.call(ctx, %{
                 "product" => product.id,
                 "content_type" => "image/png"
               })
    end

    test "accepts an allow-listed video type", %{product: product} do
      ctx = sms_ctx("+15552220012", "submitter", product)

      assert {:ok, _} =
               CreateUploadLink.call(ctx, %{
                 "product" => product.id,
                 "content_type" => "video/mp4"
               })
    end
  end

  describe "expires_in_seconds clamp" do
    test "values above the ceiling are clamped down to the ceiling",
         %{product: product} do
      ctx = sms_ctx("+15552220020", "submitter", product)

      assert {:ok, %{expires_in_seconds: 3600}} =
               CreateUploadLink.call(ctx, %{
                 "product" => product.id,
                 "expires_in_seconds" => 99_999
               })
    end

    test "zero falls back to the default 900", %{product: product} do
      ctx = sms_ctx("+15552220021", "submitter", product)

      assert {:ok, %{expires_in_seconds: 900}} =
               CreateUploadLink.call(ctx, %{
                 "product" => product.id,
                 "expires_in_seconds" => 0
               })
    end

    test "negative falls back to the default 900", %{product: product} do
      ctx = sms_ctx("+15552220022", "submitter", product)

      assert {:ok, %{expires_in_seconds: 900}} =
               CreateUploadLink.call(ctx, %{
                 "product" => product.id,
                 "expires_in_seconds" => -5
               })
    end

    test "a value inside the ceiling passes through unchanged",
         %{product: product} do
      ctx = sms_ctx("+15552220023", "submitter", product)

      assert {:ok, %{expires_in_seconds: 1200}} =
               CreateUploadLink.call(ctx, %{
                 "product" => product.id,
                 "expires_in_seconds" => 1200
               })
    end

    test "respects a custom ceiling from config", %{product: product} do
      Application.put_env(:content_forge, :open_claw_tools, max_upload_expires_seconds: 600)

      ctx = sms_ctx("+15552220024", "submitter", product)

      assert {:ok, %{expires_in_seconds: 600}} =
               CreateUploadLink.call(ctx, %{
                 "product" => product.id,
                 "expires_in_seconds" => 99_999
               })
    end
  end

  describe "product resolution still works after authorization" do
    test "product_not_found returns before the authorization gate fires",
         %{product: _product} do
      ctx = %{channel: "cli", sender_identity: "cli:nobody"}

      assert {:error, :product_not_found} =
               CreateUploadLink.call(ctx, %{"product" => "ghostship"})
    end
  end
end
