defmodule ContentForge.Jobs.BlogPublisherTest do
  @moduledoc """
  Phase 16-tail BlogPublisher coverage. Replaces the prior shim
  (which inlined `get_product_slug/1` + `get_draft_title/1` in
  this test file rather than calling the real BlogPublisher
  functions; coverage was 0%).

  Tests now hit the real `ContentForge.Jobs.BlogPublisher` API:
  the helper functions are public-for-testability with
  `@doc false`, and the HTTP delivery path is exercised through
  a config-driven `:http_post` seam so we can stub the wire
  without touching the network and assert log output is clean
  of credential strings on success / error / transport-error
  branches.
  """

  use ContentForge.DataCase, async: false

  import ExUnit.CaptureLog

  alias ContentForge.ContentGeneration
  alias ContentForge.Jobs.BlogPublisher
  alias ContentForge.Products
  alias ContentForge.Products.BlogWebhook

  describe "get_product_slug/1" do
    test "converts product name to slug" do
      assert BlogPublisher.get_product_slug(%{name: "My Test Product"}) == "my-test-product"
    end

    test "drops non-alphanumeric characters; preserves hyphens" do
      assert BlogPublisher.get_product_slug(%{name: "Test & Co. Product_123"}) ==
               "test--co-product123"
    end

    test "lowercases input" do
      assert BlogPublisher.get_product_slug(%{name: "ALREADY UPPER"}) == "already-upper"
    end
  end

  describe "get_draft_title/1" do
    test "strips a leading h1 marker" do
      draft = %{content: "# Hello World\n\nBody."}
      assert BlogPublisher.get_draft_title(draft) == "Hello World"
    end

    test "strips a leading h2 marker" do
      draft = %{content: "## Second\n\nBody."}
      assert BlogPublisher.get_draft_title(draft) == "Second"
    end

    test "falls back to 'Untitled Blog Post' on empty content" do
      assert BlogPublisher.get_draft_title(%{content: ""}) == "Untitled Blog Post"
    end

    test "falls back on whitespace-only content" do
      assert BlogPublisher.get_draft_title(%{content: "   \n\n   "}) == "Untitled Blog Post"
    end

    test "uses first non-empty line when no heading marker is present" do
      assert BlogPublisher.get_draft_title(%{content: "Just text"}) == "Just text"
    end
  end

  describe "build_payload/4 metadata-vs-content branching" do
    setup do
      {:ok, product} =
        Products.create_product(%{
          name: "Build Payload Co #{System.unique_integer()}",
          voice_profile: "professional"
        })

      draft = %{
        id: Ecto.UUID.generate(),
        content: "# Headline\n\nBody."
      }

      %{product: product, draft: draft}
    end

    test "WordPress webhook -> payload carries metadata, no inline content", %{
      product: product,
      draft: draft
    } do
      {:ok, webhook} =
        Products.create_blog_webhook(%{
          product_id: product.id,
          url: "https://hooks.example.com/cf",
          platform: "wordpress",
          wp_site_url: "https://example.com",
          wp_username: "alice",
          wp_app_password: "abcd 1234 efgh 5678"
        })

      payload = BlogPublisher.build_payload(draft, "build-payload-co", "https://r2/x.md", webhook)

      assert payload.title == "Headline"
      assert payload.product_slug == "build-payload-co"
      assert payload.r2_url == "https://r2/x.md"
      assert payload.metadata["platform"] == "wordpress"
      assert payload.metadata["wp_site_url"] == "https://example.com"
      assert payload.metadata["wp_app_password"] == "abcd 1234 efgh 5678"
      refute Map.has_key?(payload, :content)
    end

    test "Generic webhook with bearer auth -> metadata carries the token, no inline content", %{
      product: product,
      draft: draft
    } do
      {:ok, webhook} =
        Products.create_blog_webhook(%{
          product_id: product.id,
          url: "https://hooks.example.com/cf",
          platform: "generic",
          generic_auth_type: "bearer",
          generic_bearer_token: "tok-abc"
        })

      payload = BlogPublisher.build_payload(draft, "x", "https://r2/x.md", webhook)

      assert payload.metadata["platform"] == "generic"
      assert payload.metadata["generic_bearer_token"] == "tok-abc"
      refute Map.has_key?(payload, :content)
    end

    test "Generic webhook with basic auth -> metadata carries username + password" do
      {:ok, product} =
        Products.create_product(%{
          name: "Basic Auth #{System.unique_integer()}",
          voice_profile: "professional"
        })

      {:ok, webhook} =
        Products.create_blog_webhook(%{
          product_id: product.id,
          url: "https://hooks.example.com/cf",
          platform: "generic",
          generic_auth_type: "basic",
          generic_basic_username: "u",
          generic_basic_password: "p"
        })

      draft = %{id: Ecto.UUID.generate(), content: "# T\n\nB"}
      payload = BlogPublisher.build_payload(draft, "x", "https://r2/x.md", webhook)

      assert payload.metadata["generic_basic_username"] == "u"
      assert payload.metadata["generic_basic_password"] == "p"
      refute Map.has_key?(payload, :content)
    end

    test "legacy webhook (platform = nil) -> payload inlines markdown content" do
      # Bypass the changeset (which requires :platform); simulate
      # a legacy row that predates the CMS migration. The schema
      # default is "generic", so a NULL platform only happens for
      # rows persisted before the migration backfills it.
      legacy_webhook = %BlogWebhook{
        id: Ecto.UUID.generate(),
        url: "https://hooks.example.com/legacy",
        platform: nil,
        generic_auth_type: nil
      }

      draft = %{id: Ecto.UUID.generate(), content: "# Old\n\nLegacy body."}

      payload =
        BlogPublisher.build_payload(draft, "legacy-co", "https://r2/legacy.md", legacy_webhook)

      assert payload.title == "Old"
      assert payload.content == "# Old\n\nLegacy body."
      refute Map.has_key?(payload, :metadata)
    end
  end

  describe "credential redaction in delivery logs" do
    @wp_password "secret-wp-app-pw-do-not-leak"
    @bearer_token "secret-bearer-tok-do-not-leak"

    setup do
      {:ok, product} =
        Products.create_product(%{
          name: "Redaction Co #{System.unique_integer()}",
          voice_profile: "professional"
        })

      {:ok, draft} =
        ContentGeneration.create_draft(%{
          product_id: product.id,
          content: "# Title\n\nBody",
          platform: "blog",
          content_type: "blog",
          generating_model: "stub-model",
          status: "approved"
        })

      {:ok, wp_webhook} =
        Products.create_blog_webhook(%{
          product_id: product.id,
          url: "https://hooks.example.com/cf",
          platform: "wordpress",
          wp_site_url: "https://example.com",
          wp_username: "alice",
          wp_app_password: @wp_password
        })

      {:ok, generic_webhook} =
        Products.create_blog_webhook(%{
          product_id: product.id,
          url: "https://hooks.example.com/generic",
          platform: "generic",
          generic_auth_type: "bearer",
          generic_bearer_token: @bearer_token
        })

      on_exit(fn -> Application.delete_env(:content_forge, :blog_publisher) end)

      %{
        product: product,
        draft: draft,
        wp_webhook: wp_webhook,
        generic_webhook: generic_webhook
      }
    end

    defp stub_http_post(response_fn) do
      Application.put_env(:content_forge, :blog_publisher, http_post: response_fn)
    end

    test "200 success: log does not leak wp_app_password", %{
      product: product,
      draft: draft,
      wp_webhook: webhook
    } do
      stub_http_post(fn _url, _body, _headers -> {:ok, %{status: 200, body: ""}} end)

      payload = BlogPublisher.build_payload(draft, "x", "https://r2/x.md", webhook)

      log =
        capture_log(fn ->
          assert :ok = BlogPublisher.deliver_to_single_webhook(draft, product, webhook, payload)
        end)

      refute log =~ @wp_password
    end

    test "200 success: log does not leak generic_bearer_token", %{
      product: product,
      draft: draft,
      generic_webhook: webhook
    } do
      stub_http_post(fn _url, _body, _headers -> {:ok, %{status: 200, body: ""}} end)

      payload = BlogPublisher.build_payload(draft, "x", "https://r2/x.md", webhook)

      log =
        capture_log(fn ->
          assert :ok = BlogPublisher.deliver_to_single_webhook(draft, product, webhook, payload)
        end)

      refute log =~ @bearer_token
    end

    test "5xx response: error log does not leak wp_app_password", %{
      product: product,
      draft: draft,
      wp_webhook: webhook
    } do
      stub_http_post(fn _url, _body, _headers ->
        {:ok, %{status: 500, body: "Server error - please retry"}}
      end)

      payload = BlogPublisher.build_payload(draft, "x", "https://r2/x.md", webhook)

      log =
        capture_log(fn ->
          assert {:error, _} =
                   BlogPublisher.deliver_to_single_webhook(draft, product, webhook, payload)
        end)

      assert log =~ "500"
      refute log =~ @wp_password
    end

    test "transport error: error log does not leak generic_bearer_token", %{
      product: product,
      draft: draft,
      generic_webhook: webhook
    } do
      stub_http_post(fn _url, _body, _headers -> {:error, :nxdomain} end)

      payload = BlogPublisher.build_payload(draft, "x", "https://r2/x.md", webhook)

      log =
        capture_log(fn ->
          assert {:error, _} =
                   BlogPublisher.deliver_to_single_webhook(draft, product, webhook, payload)
        end)

      assert log =~ "nxdomain"
      refute log =~ @bearer_token
    end

    test "WebhookDelivery row records the success status", %{
      product: product,
      draft: draft,
      wp_webhook: webhook
    } do
      stub_http_post(fn _url, _body, _headers -> {:ok, %{status: 200, body: ""}} end)
      payload = BlogPublisher.build_payload(draft, "x", "https://r2/x.md", webhook)

      capture_log(fn ->
        BlogPublisher.deliver_to_single_webhook(draft, product, webhook, payload)
      end)

      [delivery] = ContentForge.Publishing.list_webhook_deliveries(blog_webhook_id: webhook.id)
      assert delivery.status == "success"
      assert %DateTime{} = delivery.delivered_at
    end
  end
end
