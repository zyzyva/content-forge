defmodule ContentForge.Jobs.WinnerRepurposingEngine do
  @moduledoc """
  Oban job triggered when scoreboard labels a piece as "winner".

  Generates cross-platform variants:
  - Twitter winner -> LinkedIn, Reddit, blog expansions
  - Blog winner -> social posts + video script
  - Video winner -> short-form clips, blog post

  Repurposed drafts enter Stage 3b with repurposed_from link.
  """
  use Oban.Worker, queue: :content_generation, max_attempts: 3
  require Logger

  alias ContentForge.ContentGeneration
  alias ContentForge.ContentGeneration.Draft

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"draft_id" => draft_id}}) do
    draft = ContentGeneration.get_draft!(draft_id)
    generate_repurposed_variants(draft)
  end

  def perform(%Oban.Job{args: %{"product_id" => product_id}}) do
    # Process all published content marked as winners
    # This would be triggered when scoreboard labels content as winner
    process_winner_content(product_id)
  end

  defp process_winner_content(product_id) do
    # Get all published content that was labeled as winner
    # This would check content_scoreboard for outcome = "winner"
    # For now, we'll just check for published status as a placeholder

    winners =
      ContentGeneration.list_drafts_for_product(product_id)
      |> Enum.filter(fn d -> d.status == "published" end)

    Logger.info("Processing #{length(winners)} published items for repurposing")

    Enum.each(winners, fn draft ->
      generate_repurposed_variants(draft)
    end)

    {:ok, %{repurposed: length(winners)}}
  end

  defp generate_repurposed_variants(%Draft{} = original) do
    Logger.info(
      "Generating repurposed variants for draft #{original.id} (#{original.platform}/#{original.content_type})"
    )

    # Determine target platforms based on original content type
    targets = get_repurposing_targets(original)

    Enum.each(targets, fn {platform, content_type, angle} ->
      create_repurposed_variant(original, platform, content_type, angle)
    end)

    {:ok, %{variants_created: length(targets)}}
  end

  defp get_repurposing_targets(%Draft{platform: "twitter", content_type: "post"}) do
    [
      {"linkedin", "post", "social_proof"},
      {"reddit", "post", "problem_aware"},
      {"blog", "blog", "educational"}
    ]
  end

  defp get_repurposing_targets(%Draft{platform: "linkedin", content_type: "post"}) do
    [
      {"twitter", "post", "educational"},
      {"facebook", "post", "social_proof"},
      {"blog", "blog", "case_study"}
    ]
  end

  defp get_repurposing_targets(%Draft{platform: "instagram", content_type: "post"}) do
    [
      {"twitter", "post", "entertaining"},
      {"facebook", "post", "entertaining"},
      {"tiktok", "post", "humor"}
    ]
  end

  defp get_repurposing_targets(%Draft{platform: "blog", content_type: "blog"}) do
    [
      {"twitter", "post", "educational"},
      {"linkedin", "post", "social_proof"},
      {"youtube", "video_script", "educational"}
    ]
  end

  defp get_repurposing_targets(%Draft{platform: "youtube", content_type: "video_script"}) do
    [
      {"twitter", "post", "educational"},
      {"blog", "blog", "how_to"},
      {"podcast", "post", "entertaining"}
    ]
  end

  defp get_repurposing_targets(_original) do
    # Default: create generic social variants
    [
      {"twitter", "post", "educational"},
      {"linkedin", "post", "problem_aware"}
    ]
  end

  defp create_repurposed_variant(original, platform, content_type, angle) do
    # Transform content for new platform/format
    transformed_content = transform_content(original.content, platform, content_type, angle)

    case ContentGeneration.create_draft(%{
           product_id: original.product_id,
           content_brief_id: original.content_brief_id,
           content: transformed_content,
           platform: platform,
           content_type: content_type,
           angle: angle,
           generating_model: "repurposing_engine",
           status: "draft",
           repurposed_from_id: original.id
         }) do
      {:ok, new_draft} ->
        Logger.info(
          "Created repurposed draft #{new_draft.id} from #{original.id} -> #{platform}/#{content_type}"
        )

        # Enqueue this new draft for ranking (go through normal pipeline)
        Oban.insert(%Oban.Job{
          queue: :content_generation,
          worker: "ContentForge.Jobs.MultiModelRanker",
          args: %{"product_id" => original.product_id},
          max_attempts: 3
        })

        {:ok, new_draft}

      {:error, reason} ->
        Logger.error("Failed to create repurposed variant: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp transform_content(original_content, platform, content_type, _angle) do
    # Transform the original content for the new platform/format
    # In production, this could use an LLM for better transformations

    case {platform, content_type} do
      # Blog expansion from social post
      {"blog", "blog"} ->
        expand_to_blog_post(original_content)

      # Short social post from blog
      {"twitter", "post"} ->
        shorten_for_twitter(original_content)

      {"linkedin", "post"} ->
        adapt_for_linkedin(original_content)

      {"reddit", "post"} ->
        adapt_for_reddit(original_content)

      # Video script from blog
      {"youtube", "video_script"} ->
        adapt_to_video_script(original_content)

      # Generic pass-through
      _ ->
        original_content
    end
  end

  defp expand_to_blog_post(social_content) do
    """
    #{social_content}

    ## Introduction
    Building on this topic...

    ## Main Content
    [Expanded explanation and deeper insights]

    ## Conclusion
    This is just the beginning of what's possible.
    """
  end

  defp shorten_for_twitter(blog_content) do
    # Extract first few sentences or key points
    lines = String.split(blog_content, "\n")
    key_lines = Enum.take(lines, 3)
    Enum.join(key_lines, "\n")
  end

  defp adapt_for_linkedin(social_content) do
    """
    🧵 Thread: #{social_content}

    Let me expand on this...

    [LinkedIn-optimized version with professional framing]
    """
  end

  defp adapt_for_reddit(social_content) do
    """
    I wanted to share my experience with this:

    #{social_content}

    Thoughts? Questions? Happy to discuss!
    """
  end

  defp adapt_to_video_script(blog_content) do
    """
    Video Script

    ## Hook
    [Attention-grabbing opening about the topic]

    ## Problem
    [Address the viewer's challenge]

    ## Solution
    #{blog_content}

    ## Call to Action
    [Encourage viewers to engage]
    """
  end
end
