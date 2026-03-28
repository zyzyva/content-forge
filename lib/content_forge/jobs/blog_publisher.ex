defmodule ContentForge.Jobs.BlogPublisher do
  @moduledoc """
  Oban job for publishing approved blog drafts to registered webhooks.
  On draft approval for blog type, stores markdown in R2 and delivers to webhooks.
  """

  use Oban.Worker, max_attempts: 3

  alias ContentForge.{Products, Publishing, Storage}
  alias ContentForge.ContentGeneration

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"draft_id" => draft_id}}) do
    Logger.info("BlogPublisher: Starting for draft #{draft_id}")

    case ContentGeneration.get_draft(draft_id) do
      nil ->
        Logger.error("BlogPublisher: Draft not found #{draft_id}")
        {:cancel, "Draft not found"}

      draft ->
        if draft.platform != "blog" do
          Logger.info("BlogPublisher: Draft #{draft_id} is not a blog, skipping")
          :ok
        else
          do_publish_blog(draft)
        end
    end
  end

  defp do_publish_blog(draft) do
    case Products.get_product(draft.product_id) do
      nil ->
        Logger.error("BlogPublisher: Product not found for draft #{draft.id}")
        {:cancel, "Product not found"}

      product ->
        # Store markdown in R2 with stable URL
        case store_markdown_in_r2(draft, product) do
          {:ok, r2_url} ->
            # Get active webhooks for this product
            webhooks = Products.list_active_blog_webhooks_for_product(product.id)

            if webhooks == [] do
              Logger.info("BlogPublisher: No active webhooks for product #{product.id}")
              :ok
            else
              # Deliver to each webhook
              deliver_to_webhooks(draft, product, webhooks, r2_url)
            end

          {:error, reason} ->
            Logger.error("BlogPublisher: Failed to store markdown in R2: #{reason}")
            {:error, reason}
        end
    end
  end

  defp store_markdown_in_r2(draft, product) do
    # Create stable URL: blogs/{product_slug}/{draft_id}.md
    product_slug = get_product_slug(product)
    key = "blogs/#{product_slug}/#{draft.id}.md"

    case Storage.put_object(key, draft.content, content_type: "text/markdown") do
      {:ok, url} ->
        Logger.info("BlogPublisher: Stored markdown to R2: #{url}")
        {:ok, url}

      error ->
        error
    end
  end

  defp get_product_slug(product) do
    # Derive slug from product name: lowercase, replace spaces with hyphens
    product.name
    |> String.downcase()
    |> String.replace(~r/\s+/, "-")
    |> String.replace(~r/[^a-z0-9-]/, "")
  end

  defp deliver_to_webhooks(draft, product, webhooks, r2_url) do
    product_slug = get_product_slug(product)

    payload = %{
      title: get_draft_title(draft),
      content: draft.content,
      r2_url: r2_url,
      product_slug: product_slug,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    # Deliver to each webhook
    Enum.each(webhooks, fn webhook ->
      deliver_to_single_webhook(draft, product, webhook, payload)
    end)

    :ok
  end

  defp get_draft_title(draft) do
    # Try to extract title from content (first line that looks like a heading)
    lines = String.split(draft.content, "\n", trim: true)

    case lines do
      [] ->
        "Untitled Blog Post"

      [first | _] ->
        # Remove markdown heading markers
        first
        |> String.replace(~r/^#+\s*/, "")
        |> String.trim()
        |> then(&if &1 == "", do: "Untitled Blog Post", else: &1)
    end
  end

  defp deliver_to_single_webhook(draft, product, webhook, payload) do
    body = JSON.encode!(payload)

    # HMAC-sign request body when secret present
    headers =
      if webhook.hmac_secret && webhook.hmac_secret != "" do
        signature = :crypto.mac(:hmac, :sha256, webhook.hmac_secret, body)
        signature_hex = Base.encode16(signature, case: :lower)

        [
          {"Content-Type", "application/json"},
          {"X-Hub-Signature-256", "sha256=#{signature_hex}"}
        ]
      else
        [{"Content-Type", "application/json"}]
      end

    # Record initial delivery attempt
    {:ok, delivery} =
      Publishing.create_webhook_delivery(%{
        product_id: product.id,
        blog_webhook_id: webhook.id,
        draft_id: draft.id,
        status: "pending"
      })

    case Req.post(webhook.url, body: body, headers: headers, timeout: 30_000) do
      {:ok, %{status: status}} when status >= 200 and status < 300 ->
        Logger.info("BlogPublisher: Delivered to webhook #{webhook.id}, status #{status}")

        Publishing.update_webhook_delivery(delivery, %{
          status: "success",
          delivered_at: DateTime.utc_now()
        })

        :ok

      {:ok, %{status: status, body: response_body}} ->
        error_msg = "HTTP #{status}: #{String.slice(response_body, 0, 500)}"
        Logger.error("BlogPublisher: Failed to deliver to webhook #{webhook.id}: #{error_msg}")

        Publishing.update_webhook_delivery(delivery, %{
          status: "failed",
          delivered_at: DateTime.utc_now(),
          error: error_msg
        })

        {:error, error_msg}

      {:error, reason} ->
        Logger.error(
          "BlogPublisher: Failed to deliver to webhook #{webhook.id}: #{inspect(reason)}"
        )

        Publishing.update_webhook_delivery(delivery, %{
          status: "failed",
          delivered_at: DateTime.utc_now(),
          error: inspect(reason)
        })

        {:error, reason}
    end
  end
end
