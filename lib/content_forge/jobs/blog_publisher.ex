defmodule ContentForge.Jobs.BlogPublisher do
  @moduledoc """
  Oban job for publishing approved blog drafts to registered webhooks.
  On draft approval for blog type, stores markdown in R2 and delivers to webhooks.
  """

  use Oban.Worker, max_attempts: 3

  alias ContentForge.{Products, Publishing, Storage}
  alias ContentForge.Products.BlogWebhook
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

  @doc false
  # Public for testability. Derives a URL-safe slug from a
  # product name: lowercase, spaces -> hyphens, drop anything
  # that is not alphanumeric or `-`.
  def get_product_slug(product) do
    product.name
    |> String.downcase()
    |> String.replace(~r/\s+/, "-")
    |> String.replace(~r/[^a-z0-9-]/, "")
  end

  defp deliver_to_webhooks(draft, product, webhooks, r2_url) do
    product_slug = get_product_slug(product)

    # Deliver to each webhook
    Enum.each(webhooks, fn webhook ->
      payload = build_payload(draft, product_slug, r2_url, webhook)
      deliver_to_single_webhook(draft, product, webhook, payload)
    end)

    :ok
  end

  @doc false
  # Public for testability. Builds the JSON payload sent to the
  # receiver. When the webhook has CMS metadata (any persisted
  # webhook does post-migration since `platform` defaults to
  # `"generic"`), the payload carries a `metadata` block and the
  # receiver fetches markdown from R2 via `r2_url`. The legacy
  # branch (no metadata) inlines the markdown as `content`; that
  # path remains for backward compatibility with pre-migration
  # webhooks that still have a NULL `platform`.
  def build_payload(draft, product_slug, r2_url, webhook) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    cms_meta = BlogWebhook.cms_metadata(webhook)

    payload = %{
      title: get_draft_title(draft),
      r2_url: r2_url,
      product_slug: product_slug,
      timestamp: timestamp
    }

    if map_size(cms_meta) > 0 do
      Map.put(payload, :metadata, cms_meta)
    else
      Map.put(payload, :content, draft.content)
    end
  end

  @doc false
  # Public for testability. Extracts a title from the first
  # non-empty line of the draft, stripping markdown heading
  # markers; falls back to "Untitled Blog Post" for empty content
  # or empty heading lines.
  def get_draft_title(draft) do
    lines = String.split(draft.content, "\n", trim: true)

    case lines do
      [] ->
        "Untitled Blog Post"

      [first | _] ->
        first
        |> String.replace(~r/^#+\s*/, "")
        |> String.trim()
        |> then(&if &1 == "", do: "Untitled Blog Post", else: &1)
    end
  end

  @doc false
  # Public for testability. Performs the actual HTTP delivery
  # for one webhook (HMAC-signs the body when a secret is set,
  # records the WebhookDelivery row, logs success/error). The
  # `:http_post` Application env hook in `http_post/0` lets tests
  # stub the wire without touching the network.
  def deliver_to_single_webhook(draft, product, webhook, payload) do
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

    case http_post().(webhook.url, body, headers) do
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

  # Test seam. Defaults to `Req.post/2`. Tests override via
  # `Application.put_env(:content_forge, :blog_publisher, http_post: fn ... end)`
  # so a fake HTTP client can stand in without touching the
  # network and so log-output assertions can run deterministically.
  defp http_post do
    Application.get_env(:content_forge, :blog_publisher, [])
    |> Keyword.get(:http_post, &default_http_post/3)
  end

  defp default_http_post(url, body, headers) do
    Req.post(url, body: body, headers: headers, timeout: 30_000)
  end
end
