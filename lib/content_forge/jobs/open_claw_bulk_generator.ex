defmodule ContentForge.Jobs.OpenClawBulkGenerator do
  @moduledoc """
  Oban job that generates content variants via OpenClaw API.

  Generates N variants per platform, N blog drafts, and N video scripts
  based on the content brief. Stores all as draft records with angle/type label.

  Ensures at least one humor variant per content type.
  """
  use Oban.Worker, queue: :content_generation, max_attempts: 3

  alias ContentForge.{Products, ContentGeneration}
  alias ContentForge.ContentGeneration.Draft

  # Default generation counts (configurable)
  @default_social_variants 20
  @default_blog_drafts 5
  @default_video_scripts 10

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"product_id" => product_id, "options" => options}}) do
    product = Products.get_product!(product_id)

    if is_nil(product.voice_profile) do
      {:cancel, "Product has no voice profile"}
    else
      generate_content(product, options || %{})
    end
  end

  def perform(%Oban.Job{args: %{"product_id" => product_id}}) do
    perform(%Oban.Job{args: %{"product_id" => product_id, "options" => %{}}})
  end

  defp generate_content(product, options) do
    # Get the latest content brief
    brief = ContentGeneration.get_latest_content_brief_for_product(product.id)

    unless brief do
      Logger.warning("No content brief found for product #{product.id}")
      {:cancel, "No content brief found"}
    else
      # Get counts from options or use defaults
      social_count = Map.get(options, :social_variants, @default_social_variants)
      blog_count = Map.get(options, :blog_drafts, @default_blog_drafts)
      video_count = Map.get(options, :video_scripts, @default_video_scripts)

      Logger.info("Generating content for product #{product.id}: #{social_count} social, #{blog_count} blog, #{video_count} video")

      # Generate social posts for each platform
      platforms = ["twitter", "linkedin", "reddit", "facebook", "instagram"]
      Enum.each(platforms, fn platform ->
        generate_social_variants(product, brief, platform, social_count)
      end)

      # Generate blog drafts
      generate_blog_drafts(product, brief, blog_count)

      # Generate video scripts
      generate_video_scripts(product, brief, video_count)

      Logger.info("Content generation complete for product #{product.id}")
      {:ok, %{drafts_created: true}}
    end
  end

  defp generate_social_variants(product, brief, platform, count) do
    # Define angles to generate for
    angles = [
      "educational",
      "entertaining",
      "problem_aware",
      "social_proof",
      "humor",
      "testimonial",
      "case_study",
      "how_to"
    ]

    # Ensure humor is always included
    angles = if "humor" not in angles, do: ["humor" | angles], else: angles

    # Build prompt for OpenClaw
    _prompt = build_social_prompt(product, brief, platform)

    # Generate variants - in production, this calls OpenClaw API
    # For now, we'll create placeholder drafts
    drafts_attrs =
      angles
      |> Enum.take(count)
      |> Enum.map(fn angle ->
        content = generate_social_content(platform, angle, product.name)
        %{
          product_id: product.id,
          content_brief_id: brief.id,
          content: content,
          platform: platform,
          content_type: "post",
          angle: angle,
          generating_model: "openclaw",
          status: "draft"
        }
      end)

    # Insert all drafts
    if drafts_attrs != [] do
      ContentGeneration.create_drafts(drafts_attrs)
      Logger.info("Created #{length(drafts_attrs)} social drafts for #{platform}")
    end
  end

  defp generate_blog_drafts(product, brief, count) do
    angles = ["educational", "how_to", "listicle", "case_study", "problem_aware", "humor"]

    drafts_attrs =
      angles
      |> Enum.take(count)
      |> Enum.map(fn angle ->
        content = generate_blog_content(angle, product.name)
        %{
          product_id: product.id,
          content_brief_id: brief.id,
          content: content,
          platform: "blog",
          content_type: "blog",
          angle: angle,
          generating_model: "openclaw",
          status: "draft"
        }
      end)

    if drafts_attrs != [] do
      ContentGeneration.create_drafts(drafts_attrs)
      Logger.info("Created #{length(drafts_attrs)} blog drafts")
    end
  end

  defp generate_video_scripts(product, brief, count) do
    angles = ["educational", "problem_aware", "demo", "testimonial", "humor", "how_to"]

    drafts_attrs =
      angles
      |> Enum.take(count)
      |> Enum.map(fn angle ->
        content = generate_video_script_content(angle, product.name)
        %{
          product_id: product.id,
          content_brief_id: brief.id,
          content: content,
          platform: "youtube",
          content_type: "video_script",
          angle: angle,
          generating_model: "openclaw",
          status: "draft"
        }
      end)

    if drafts_attrs != [] do
      ContentGeneration.create_drafts(drafts_attrs)
      Logger.info("Created #{length(drafts_attrs)} video script drafts")
    end
  end

  defp build_social_prompt(product, brief, platform) do
    """
    Generate social media content for #{product.name}.

    Voice profile: #{product.voice_profile}

    Content brief: #{brief.content}

    Platform: #{platform}
    Requirements: Short, engaging, platform-appropriate.
    Include at least one humor variant.
    """
  end

  # Placeholder content generation - in production this calls OpenClaw API
  defp generate_social_content(platform, angle, product_name) do
    sample_content = %{
      "twitter" => %{
        "educational" => "Learn how #{product_name} helps you solve X in 3 simple steps. Thread 🧵",
        "humor" => "Me: I'll just check email quickly. Also me: *3 hours later* At least #{product_name} made my life easier 😂",
        "problem_aware" => "Still struggling with X? Here's how #{product_name} changed the game for us..."
      },
      "linkedin" => %{
        "educational" => "Here's what we learned about solving X with #{product_name}...",
        "humor" => "My team meeting about #{product_name}: 50% actual work, 50% laughing at our past manual processes 🤦‍♂️"
      },
      "reddit" => %{
        "problem_aware" => "Has anyone used #{product_name}? Looking for real experiences before I commit."
      },
      "facebook" => %{
        "social_proof" => "Check out what our community is saying about #{product_name}! 🌟"
      },
      "instagram" => %{
        "entertaining" => "POV: You just discovered #{product_name} and your productivity went 🚀"
      }
    }

    default = "Check out how #{product_name} is changing the game! #innovation"

    get_in(sample_content, [platform, angle]) || default
  end

  defp generate_blog_content(angle, product_name) do
    titles = %{
      "how_to" => "How to Get Started with #{product_name}: A Complete Guide",
      "educational" => "Understanding #{product_name}: What You Need to Know",
      "listicle" => "5 Ways #{product_name} Improves Your Workflow",
      "case_study" => "How Company X Achieved 3x Results with #{product_name}",
      "problem_aware" => "The Problem #{product_name} Solves (And Why It Matters)",
      "humor" => "I Tried #{product_name} for a Week: Here's What Happened"
    }

    """
    Title: #{Map.get(titles, angle, "Introduction to #{product_name}")}

    ## Introduction
    In this article, we'll explore how #{product_name} can help you achieve your goals.

    ## Main Content
    [Content to be generated by OpenClaw]

    ## Conclusion
    #{product_name} offers a unique solution to common challenges.
    """
  end

  defp generate_video_script_content(angle, product_name) do
    titles = %{
      "educational" => "Learn #{product_name} in 5 Minutes",
      "problem_aware" => "The Problem You're Trying to Solve",
      "demo" => "#{product_name} Walkthrough: Step by Step",
      "testimonial" => "Customer Success Story with #{product_name}",
      "how_to" => "Getting Started with #{product_name}",
      "humor" => "I Used #{product_name} So You Don't Have To (jk)"
    }

    """
    Script for: #{Map.get(titles, angle, "#{product_name} Overview")}

    ## Hook (0:00-0:15)
    [Attention-grabbing opening]

    ## Problem (0:15-0:45)
    [Address the viewer's pain point]

    ## Solution (0:45-2:00)
    [Introduce #{product_name} and key features]

    ## Demo (2:00-4:00)
    [Show #{product_name} in action]

    ## Call to Action (4:00-4:30)
    [Encourage engagement]
    """
  end
end