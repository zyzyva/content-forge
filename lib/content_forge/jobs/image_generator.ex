defmodule ContentForge.Jobs.ImageGenerator do
  @moduledoc """
  Oban job that generates images for social posts via Media Forge.

  For each ranked social post (content_type = "post") without an image, builds
  an image prompt from the post text and product branding and requests image
  generation through `ContentForge.MediaForge.generate_images/1`. Media Forge
  selects the underlying provider (Flux, DALL-E, or other) internally, stores
  the result in R2, and returns either a synchronous image URL or an async
  job id that this worker resolves by polling `MediaForge.get_job/1`.

  When Media Forge is not configured on this deployment (no shared secret),
  the worker logs the condition, returns `{:ok, :skipped}`, and leaves the
  draft's `image_url` nil. No placeholder URL is ever written.
  """

  use Oban.Worker, queue: :content_generation, max_attempts: 3

  alias ContentForge.ContentGeneration
  alias ContentForge.MediaForge
  alias ContentForge.MediaForge.JobResolver
  alias ContentForge.Products

  require Logger

  @default_poll_interval_ms 3_000
  @default_poll_max_attempts 20

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"draft_id" => draft_id}}) do
    draft_id
    |> ContentGeneration.get_draft!()
    |> generate_for_draft()
  end

  def perform(%Oban.Job{args: %{"product_id" => product_id}}) do
    process_all_social_posts(product_id)
  end

  defp process_all_social_posts(product_id) do
    drafts =
      product_id
      |> ContentGeneration.list_drafts_by_type("post")
      |> Enum.filter(&needs_image?/1)

    Logger.info("ImageGenerator: enqueuing #{length(drafts)} social posts for image generation")

    Enum.each(drafts, fn draft ->
      %{"draft_id" => draft.id}
      |> __MODULE__.new()
      |> Oban.insert()
    end)

    {:ok, %{enqueued: length(drafts)}}
  end

  defp needs_image?(%{status: "ranked", image_url: nil}), do: true
  defp needs_image?(_), do: false

  # --- per-draft generation --------------------------------------------------

  defp generate_for_draft(%{content_type: content_type} = _draft) when content_type != "post" do
    {:ok, :skipped_non_post}
  end

  defp generate_for_draft(%{image_url: url}) when is_binary(url) and url != "" do
    {:ok, :already_attached}
  end

  defp generate_for_draft(draft) do
    product = Products.get_product!(draft.product_id)
    prompt = build_image_prompt(draft, product)

    request = %{
      prompt: prompt,
      metadata: %{
        draft_id: draft.id,
        product_id: draft.product_id,
        platform: draft.platform
      }
    }

    request
    |> MediaForge.generate_images()
    |> handle_generate_response(draft)
  end

  # --- Media Forge response handling -----------------------------------------

  defp handle_generate_response({:ok, %{"image_url" => url} = body}, draft)
       when is_binary(url) do
    apply_sync_done(draft, body)
  end

  defp handle_generate_response({:ok, %{"url" => url} = body}, draft) when is_binary(url) do
    apply_sync_done(draft, body)
  end

  defp handle_generate_response({:ok, %{"result" => %{"image_url" => url}} = body}, draft)
       when is_binary(url) do
    apply_sync_done(draft, body)
  end

  defp handle_generate_response({:ok, %{"jobId" => job_id}}, draft) when is_binary(job_id) do
    Logger.info("ImageGenerator: draft #{draft.id} awaiting Media Forge job #{job_id}")
    {:ok, draft} = ContentGeneration.update_draft(draft, %{media_forge_job_id: job_id})
    poll_until_done(job_id, draft, poll_max_attempts())
  end

  defp handle_generate_response({:ok, body}, draft) do
    Logger.error(
      "ImageGenerator: draft #{draft.id} unrecognized Media Forge sync response #{inspect(body)}"
    )

    {:cancel, "unrecognized Media Forge response"}
  end

  defp handle_generate_response({:error, :not_configured}, draft) do
    Logger.warning(
      "ImageGenerator: Media Forge unavailable (no secret configured); skipping draft #{draft.id}"
    )

    {:ok, :skipped}
  end

  defp handle_generate_response({:error, {:http_error, status, body}}, draft) do
    Logger.error(
      "ImageGenerator: draft #{draft.id} Media Forge permanent error #{status} #{inspect(body)}"
    )

    {:cancel, "Media Forge rejected request (HTTP #{status})"}
  end

  defp handle_generate_response({:error, {:transient, _, _} = reason}, draft) do
    Logger.warning(
      "ImageGenerator: draft #{draft.id} Media Forge transient error #{inspect(reason)}; Oban will retry"
    )

    {:error, reason}
  end

  defp handle_generate_response({:error, {:unexpected_status, status, _body}}, draft) do
    Logger.error(
      "ImageGenerator: draft #{draft.id} Media Forge returned unexpected status #{status}"
    )

    {:cancel, "Media Forge returned unexpected HTTP status #{status}"}
  end

  defp handle_generate_response({:error, reason}, draft) do
    Logger.error(
      "ImageGenerator: draft #{draft.id} unexpected Media Forge error #{inspect(reason)}"
    )

    {:error, reason}
  end

  defp apply_sync_done(draft, body) do
    case JobResolver.apply_image_done(draft, body) do
      {:ok, :done, url} ->
        Logger.info("ImageGenerator: attached image to draft #{draft.id}")
        {:ok, url}

      {:ok, :failed, reason} ->
        {:cancel, reason}

      {:ok, :noop} ->
        {:ok, draft.image_url || :already_attached}
    end
  end

  # --- polling ---------------------------------------------------------------

  defp poll_until_done(_job_id, _draft, 0), do: {:error, :media_forge_job_poll_timeout}

  defp poll_until_done(job_id, draft, attempts_left) do
    job_id
    |> MediaForge.get_job()
    |> handle_poll_response(job_id, draft, attempts_left)
  end

  defp handle_poll_response({:ok, %{"status" => status} = body}, _job_id, draft, _attempts_left)
       when status in ["done", "completed", "succeeded"] do
    case JobResolver.apply_image_done(draft, body) do
      {:ok, :done, url} ->
        Logger.info("ImageGenerator: attached image to draft #{draft.id}")
        {:ok, url}

      {:ok, :failed, reason} ->
        Logger.error(
          "ImageGenerator: draft #{draft.id} Media Forge reported done but no image url in #{inspect(body)}"
        )

        {:cancel, reason}

      {:ok, :noop} ->
        {:ok, draft.image_url || :already_attached}
    end
  end

  defp handle_poll_response({:ok, %{"status" => status} = body}, job_id, draft, _attempts_left)
       when status in ["failed", "error"] do
    reason = body["error"] || body["message"] || "unknown"

    Logger.error(
      "ImageGenerator: draft #{draft.id} Media Forge job #{job_id} failed: #{inspect(reason)}"
    )

    _ = JobResolver.apply_image_failed(draft, to_string(reason))
    {:cancel, "Media Forge image job failed: #{inspect(reason)}"}
  end

  defp handle_poll_response({:ok, _body}, job_id, draft, attempts_left) do
    Process.sleep(poll_interval_ms())
    poll_until_done(job_id, draft, attempts_left - 1)
  end

  defp handle_poll_response({:error, :not_configured}, _job_id, draft, _attempts_left) do
    Logger.warning(
      "ImageGenerator: Media Forge became unavailable while polling draft #{draft.id}"
    )

    {:ok, :skipped}
  end

  defp handle_poll_response({:error, reason} = err, job_id, draft, _attempts_left) do
    Logger.error(
      "ImageGenerator: draft #{draft.id} poll of Media Forge job #{job_id} errored: #{inspect(reason)}"
    )

    err
  end

  # --- prompt ----------------------------------------------------------------

  defp build_image_prompt(draft, product) do
    """
    Create a social media image for a post about #{product.name}.

    Post content: #{draft.content}
    Platform: #{draft.platform}
    Angle: #{draft.angle}
    Brand voice: #{product.voice_profile}

    Style: Modern, engaging, #{platform_style(draft.platform)}
    Include brand-appropriate colors and imagery.
    """
  end

  defp platform_style("twitter"), do: "clean and minimalist"
  defp platform_style("linkedin"), do: "professional and sophisticated"
  defp platform_style("instagram"), do: "vibrant and visual"
  defp platform_style("facebook"), do: "warm and inviting"
  defp platform_style("reddit"), do: "authentic and community-focused"
  defp platform_style(_), do: "versatile and engaging"

  # --- config ---------------------------------------------------------------

  defp poll_interval_ms do
    get_config(:poll_interval_ms, @default_poll_interval_ms)
  end

  defp poll_max_attempts do
    get_config(:poll_max_attempts, @default_poll_max_attempts)
  end

  defp get_config(key, default) do
    :content_forge
    |> Application.get_env(:image_generator, [])
    |> Keyword.get(key, default)
  end
end
