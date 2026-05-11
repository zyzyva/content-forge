defmodule ContentForge.Products.BlogWebhookTest do
  use ContentForge.DataCase, async: true

  alias ContentForge.Products
  alias ContentForge.Products.BlogWebhook

  defp product!(name \\ "Webhook Schema Product") do
    {:ok, p} =
      Products.create_product(%{
        name: "#{name} #{System.unique_integer()}",
        voice_profile: "professional"
      })

    p
  end

  describe "changeset/2 baseline" do
    test "valid generic webhook (default platform) inserts cleanly" do
      product = product!()

      assert {:ok, %BlogWebhook{} = webhook} =
               Products.create_blog_webhook(%{
                 product_id: product.id,
                 url: "https://hooks.example.com/cf",
                 hmac_secret: "shhh",
                 platform: "generic"
               })

      assert webhook.platform == "generic"
      assert webhook.active == true
    end

    test "rejects a missing url with required-field error" do
      product = product!()

      assert {:error, changeset} =
               Products.create_blog_webhook(%{product_id: product.id, platform: "generic"})

      assert "can't be blank" in errors_on(changeset).url
    end

    test "rejects a non-http url" do
      product = product!()

      assert {:error, changeset} =
               Products.create_blog_webhook(%{
                 product_id: product.id,
                 url: "ftp://nope",
                 platform: "generic"
               })

      assert Enum.any?(errors_on(changeset).url, &(&1 =~ "invalid"))
    end
  end

  describe "platform inclusion" do
    test "accepts wordpress (with full WP creds) and generic" do
      product = product!()

      assert {:ok, _} =
               Products.create_blog_webhook(
                 Map.merge(base_attrs(product, "wordpress"), %{
                   "wp_site_url" => "https://example.com",
                   "wp_username" => "alice",
                   "wp_app_password" => "abcd 1234 efgh 5678"
                 })
               )

      assert {:ok, _} = Products.create_blog_webhook(base_attrs(product, "generic"))
    end

    test "rejects anything else with platform inclusion error" do
      product = product!()

      assert {:error, changeset} =
               Products.create_blog_webhook(base_attrs(product, "ghost"))

      assert "is invalid" in errors_on(changeset).platform
    end
  end

  describe "WordPress-required validations on insert" do
    test "rejects WordPress platform without wp_site_url" do
      product = product!()

      attrs =
        base_attrs(product, "wordpress")
        |> Map.merge(%{
          "wp_username" => "alice",
          "wp_app_password" => "abcd 1234 efgh 5678"
        })

      assert {:error, changeset} = Products.create_blog_webhook(attrs)
      assert "required for WordPress platform" in errors_on(changeset).wp_site_url
    end

    test "rejects WordPress platform with malformed wp_site_url" do
      product = product!()

      attrs =
        base_attrs(product, "wordpress")
        |> Map.merge(%{
          "wp_site_url" => "not-a-url",
          "wp_username" => "alice",
          "wp_app_password" => "abcd 1234 efgh 5678"
        })

      assert {:error, changeset} = Products.create_blog_webhook(attrs)
      assert "must be a valid URL" in errors_on(changeset).wp_site_url
    end

    test "accepts a fully-specified WordPress webhook" do
      product = product!()

      attrs =
        base_attrs(product, "wordpress")
        |> Map.merge(%{
          "wp_site_url" => "https://example.com",
          "wp_username" => "alice",
          "wp_app_password" => "abcd 1234 efgh 5678"
        })

      assert {:ok, %BlogWebhook{platform: "wordpress"}} =
               Products.create_blog_webhook(attrs)
    end
  end

  describe "WordPress-required validations on update (must-fix #2)" do
    setup do
      product = product!()

      {:ok, wp} =
        Products.create_blog_webhook(%{
          product_id: product.id,
          url: "https://hooks.example.com/cf",
          platform: "wordpress",
          wp_site_url: "https://example.com",
          wp_username: "alice",
          wp_app_password: "abcd 1234 efgh 5678"
        })

      %{webhook: wp}
    end

    test "fails when wp_site_url is set to nil and platform is unchanged", %{webhook: wp} do
      assert {:error, changeset} =
               Products.update_blog_webhook(wp, %{wp_site_url: nil})

      assert "required for WordPress platform" in errors_on(changeset).wp_site_url
    end

    test "fails when wp_app_password is blanked and platform is unchanged", %{webhook: wp} do
      assert {:error, changeset} =
               Products.update_blog_webhook(wp, %{wp_app_password: ""})

      assert "required for WordPress platform" in errors_on(changeset).wp_app_password
    end

    test "succeeds when switching from wordpress to generic, even with WP fields nilled", %{
      webhook: wp
    } do
      assert {:ok, updated} =
               Products.update_blog_webhook(wp, %{
                 platform: "generic",
                 wp_site_url: nil
               })

      assert updated.platform == "generic"
    end
  end

  describe "cms_metadata/1" do
    test "WordPress shape includes wp_* keys, omits empty generic_* keys" do
      product = product!()

      {:ok, wp} =
        Products.create_blog_webhook(%{
          product_id: product.id,
          url: "https://hooks.example.com/cf",
          platform: "wordpress",
          wp_site_url: "https://example.com",
          wp_username: "alice",
          wp_app_password: "abcd 1234 efgh 5678"
        })

      meta = BlogWebhook.cms_metadata(wp)

      assert meta["platform"] == "wordpress"
      assert meta["wp_site_url"] == "https://example.com"
      assert meta["wp_username"] == "alice"
      assert meta["wp_app_password"] == "abcd 1234 efgh 5678"
      refute Map.has_key?(meta, "generic_bearer_token")
      refute Map.has_key?(meta, "generic_basic_password")
    end

    test "Generic webhook with bearer auth includes generic_bearer_token, omits wp_*" do
      product = product!()

      {:ok, generic} =
        Products.create_blog_webhook(%{
          product_id: product.id,
          url: "https://hooks.example.com/cf",
          platform: "generic",
          generic_auth_type: "bearer",
          generic_bearer_token: "tok-abc"
        })

      meta = BlogWebhook.cms_metadata(generic)

      assert meta["platform"] == "generic"
      assert meta["generic_auth_type"] == "bearer"
      assert meta["generic_bearer_token"] == "tok-abc"
      refute Map.has_key?(meta, "wp_site_url")
      refute Map.has_key?(meta, "wp_app_password")
    end

    test "Generic webhook with basic auth includes generic_basic_username + password" do
      product = product!()

      {:ok, generic} =
        Products.create_blog_webhook(%{
          product_id: product.id,
          url: "https://hooks.example.com/cf",
          platform: "generic",
          generic_auth_type: "basic",
          generic_basic_username: "u",
          generic_basic_password: "p"
        })

      meta = BlogWebhook.cms_metadata(generic)

      assert meta["generic_basic_username"] == "u"
      assert meta["generic_basic_password"] == "p"
      refute Map.has_key?(meta, "generic_bearer_token")
    end

    test "Generic webhook with none auth omits all credential keys" do
      product = product!()

      {:ok, generic} =
        Products.create_blog_webhook(%{
          product_id: product.id,
          url: "https://hooks.example.com/cf",
          platform: "generic",
          generic_auth_type: "none"
        })

      meta = BlogWebhook.cms_metadata(generic)

      assert meta["generic_auth_type"] == "none"
      refute Map.has_key?(meta, "generic_bearer_token")
      refute Map.has_key?(meta, "generic_basic_username")
      refute Map.has_key?(meta, "generic_basic_password")
    end
  end

  describe "platform_name/1" do
    test "humanizes the known platform values" do
      assert BlogWebhook.platform_name("wordpress") == "WordPress"
      assert BlogWebhook.platform_name("generic") == "Generic Webhook"
      assert BlogWebhook.platform_name("anything-else") == "Unknown"
    end
  end

  defp base_attrs(product, platform) do
    %{
      "product_id" => product.id,
      "url" => "https://hooks.example.com/cf",
      "platform" => platform
    }
  end
end
