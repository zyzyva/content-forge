defmodule ContentForge.Publishing.WebhookDeliveryTest do
  @moduledoc """
  Smoke tests for the `WebhookDelivery` schema's changeset. Added
  during the 15.3a coverage-uplift triage to bring the module
  above the 0% baseline; the schema is tiny but it does have
  validation rules worth regression-pinning.
  """
  use ContentForge.DataCase, async: true

  alias ContentForge.ContentGeneration
  alias ContentForge.Products
  alias ContentForge.Publishing.WebhookDelivery

  setup do
    {:ok, product} =
      Products.create_product(%{name: "Webhook Delivery Product", voice_profile: "professional"})

    {:ok, webhook} =
      Products.create_blog_webhook(%{
        product_id: product.id,
        url: "https://example.com/hook",
        hmac_secret: "shhh"
      })

    {:ok, draft} =
      ContentGeneration.create_draft(%{
        "product_id" => product.id,
        "content" => "content",
        "platform" => "blog",
        "content_type" => "blog",
        "generating_model" => "test",
        "status" => "approved"
      })

    %{product: product, webhook: webhook, draft: draft}
  end

  test "validates required associations and status values", %{
    product: product,
    webhook: webhook,
    draft: draft
  } do
    attrs = %{
      product_id: product.id,
      blog_webhook_id: webhook.id,
      draft_id: draft.id,
      status: "pending"
    }

    assert %Ecto.Changeset{valid?: true} = WebhookDelivery.changeset(%WebhookDelivery{}, attrs)

    assert %Ecto.Changeset{valid?: false, errors: errors} =
             WebhookDelivery.changeset(%WebhookDelivery{}, %{attrs | status: "bogus"})

    assert Keyword.has_key?(errors, :status)

    assert %Ecto.Changeset{valid?: false, errors: missing_errors} =
             WebhookDelivery.changeset(%WebhookDelivery{}, %{})

    assert Keyword.has_key?(missing_errors, :product_id)
    assert Keyword.has_key?(missing_errors, :blog_webhook_id)
    assert Keyword.has_key?(missing_errors, :draft_id)
    assert Keyword.has_key?(missing_errors, :status)
  end

  test "exposes canonical status constants" do
    assert WebhookDelivery.pending_status() == "pending"
    assert WebhookDelivery.success_status() == "success"
    assert WebhookDelivery.failed_status() == "failed"
  end
end
