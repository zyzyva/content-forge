defmodule ContentForge.Jobs.ImageGenerator do
  @moduledoc """
  Oban job that generates images for social posts.

  For each ranked social post, a smart model writes an image prompt from post text
  + product branding. Image is generated via configurable provider (Flux/DALL-E),
  stored in R2, and linked to the draft.
  """
  use Oban.Worker, queue: :content_generation, max_attempts: 3
  require Logger

  alias ContentForge.{Products, ContentGeneration}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"draft_id" => draft_id, "provider" => provider}}) do
    draft = ContentGeneration.get_draft!(draft_id)
    generate_image_for_draft(draft, provider || :flux)
  end

  def perform(%Oban.Job{args: %{"draft_id" => draft_id}}) do
    draft = ContentGeneration.get_draft!(draft_id)
    generate_image_for_draft(draft, :flux)
  end

  def perform(%Oban.Job{args: %{"product_id" => product_id}}) do
    # Process all ranked social posts for the product
    process_all_social_posts(product_id)
  end

  defp process_all_social_posts(product_id) do
    # Get all ranked social posts that don't have images yet
    drafts =
      ContentGeneration.list_drafts_by_type(product_id, "post")
      |> Enum.filter(fn d -> d.status == "ranked" && is_nil(d.image_url) end)

    Logger.info("Generating images for #{length(drafts)} social posts")

    Enum.each(drafts, fn draft ->
      # Enqueue individual image generation jobs
      Oban.insert(%Oban.Job{
        queue: :image_generation,
        worker: "ContentForge.Jobs.ImageGenerator",
        args: %{"draft_id" => draft.id, "provider" => "flux"},
        max_attempts: 3
      })
    end)

    {:ok, %{enqueued: length(drafts)}}
  end

  defp generate_image_for_draft(draft, provider) do
    # Only generate for social posts
    unless draft.content_type == "post" do
      Logger.info("Skipping image generation for non-social post #{draft.id}")
      {:ok, :skipped}
    else
      # Get product for branding context
      product = Products.get_product!(draft.product_id)

      # Generate image prompt using smart model
      prompt = generate_image_prompt(draft, product)

      # Generate image via provider
      image_url = generate_image(prompt, provider, draft.id)

      if image_url do
        # Update draft with image URL
        ContentGeneration.update_draft(draft, %{image_url: image_url})
        Logger.info("Generated and attached image for draft #{draft.id}")
        {:ok, image_url}
      else
        {:error, "Failed to generate image"}
      end
    end
  end

  defp generate_image_prompt(draft, product) do
    # Build a prompt for the image model
    # In production, this would call a smart model to create the prompt
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

  defp generate_image(_prompt, _provider, draft_id) do
    # Placeholder - in production, this would call Flux/DALL-E API
    # For now, we'll use a placeholder image URL

    # In production:
    # case provider do
    #   :flux -> call_flux_api(prompt)
    #   :dalle -> call_dalle_api(prompt)
    # end

    # Generate a placeholder - in real implementation, this would be an R2 URL
    "https://placeholder.contentforge.dev/images/#{draft_id}.png"
  end
end
