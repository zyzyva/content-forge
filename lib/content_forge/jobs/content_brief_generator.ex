defmodule ContentForge.Jobs.ContentBriefGenerator do
  @moduledoc """
  Oban job that generates or rewrites a content brief for a product.

  On first run: queries smart models (Claude/Gemini/xAI) with snapshot + competitor intel
  to synthesize an initial brief.

  On subsequent runs: rewrites the brief using scoreboard + calibration + competitor intel
  when performance data exists.
  """
  use Oban.Worker, queue: :content_generation, max_attempts: 3

  alias ContentForge.{Products, ContentGeneration, Storage}
  alias ContentForge.Products.Product

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"product_id" => product_id, "force_rewrite" => force_rewrite}}) do
    product = Products.get_product!(product_id)

    if is_nil(product.voice_profile) do
      Logger.warning("Product #{product_id} has no voice profile, skipping brief generation")
      {:cancel, "Product has no voice profile"}
    else
      generate_or_rewrite_brief(product, force_rewrite || false)
    end
  end

  def perform(%Oban.Job{args: %{"product_id" => product_id}}) do
    perform(%Oban.Job{args: %{"product_id" => product_id, "force_rewrite" => false}})
  end

  defp generate_or_rewrite_brief(product, force_rewrite) do
    # Get latest snapshot and competitor intel
    snapshot = Products.get_latest_snapshot_for_product(product.id, "full")
    competitor_intel = Products.get_latest_competitor_intel_for_product(product.id)

    # Check if brief already exists
    existing_brief = ContentGeneration.get_latest_content_brief_for_product(product.id)

    if existing_brief && !force_rewrite do
      Logger.info("Content brief already exists for product #{product.id}, skipping initial generation")
      {:ok, existing_brief}
    else
      # Determine if we should rewrite based on performance data
      should_rewrite = existing_brief && has_significant_performance_data?(product.id)

      if should_rewrite do
        rewrite_brief_with_performance(product, existing_brief, snapshot, competitor_intel)
      else
        generate_initial_brief(product, snapshot, competitor_intel)
      end
    end
  end

  defp has_significant_performance_data?(product_id) do
    # Check if there are enough measured pieces to trigger a rewrite
    # For now, we'll check if content_scoreboard has entries
    # This would be implemented when Phase 7 is complete
    false
  end

  defp generate_initial_brief(product, snapshot, competitor_intel) do
    # Build context for smart model
    context = build_brief_context(product, snapshot, competitor_intel, nil)

    # Query multiple smart models and synthesize
    # For now, we'll use a single model as placeholder
    brief_content = query_smart_model_for_brief(context)

    # Create the content brief
    {:ok, brief} =
      ContentGeneration.create_content_brief(%{
        product_id: product.id,
        version: 1,
        content: brief_content,
        snapshot_id: snapshot && snapshot.id,
        competitor_intel_id: competitor_intel && competitor_intel.id,
        model_used: "claude"
      })

    Logger.info("Created initial content brief v1 for product #{product.id}")
    {:ok, brief}
  end

  defp rewrite_brief_with_performance(product, existing_brief, snapshot, competitor_intel) do
    # Get performance scoreboard and model calibration data
    # This would come from Phase 7 when implemented
    performance_summary = %{}

    # Build context with performance insights
    context = build_brief_context(product, snapshot, competitor_intel, performance_summary)

    # Query smart model for rewrite
    new_brief_content = query_smart_model_for_brief_rewrite(context, existing_brief.content)

    # Create new version
    {:ok, new_brief} =
      ContentGeneration.create_new_brief_version(
        existing_brief,
        new_brief_content,
        performance_summary,
        "Performance-based rewrite"
      )

    Logger.info("Created content brief v#{new_brief.version} for product #{product.id}")
    {:ok, new_brief}
  end

  defp build_brief_context(product, snapshot, competitor_intel, _performance_summary) do
    %{
      product_name: product.name,
      voice_profile: product.voice_profile,
      repo_url: product.repo_url,
      site_url: product.site_url,
      snapshot_content: snapshot && snapshot.content,
      competitor_intel_content: competitor_intel && competitor_intel.summary,
      # performance_summary would include scoreboard data when Phase 7 is done
      performance_summary: %{}
    }
  end

  defp query_smart_model_for_brief(context) do
    # This is a placeholder - in production, this would call Claude/Gemini/xAI
    # The actual implementation would use the LLM client
    """
    Content Brief for #{context.product_name}

    ## Voice Profile
    #{context.voice_profile}

    ## Target Audience
    [To be determined based on product analysis]

    ## Content Pillars
    - Educational content explaining product features and benefits
    - Problem-aware content addressing customer pain points
    - Social proof through customer success stories
    - Entertaining content that humanizes the brand

    ## Content Angles (Required)
    - educational: Explain concepts, how-tos, tutorials
    - entertaining: Humor, storytelling, engaging narratives
    - problem_aware: Address pain points, challenges
    - social_proof: Testimonials, case studies, success stories
    - testimonial: Customer quotes and experiences

    ## Platform-Specific Guidelines
    - Twitter/X: Short, punchy, hook-driven, max 280 chars
    - LinkedIn: Professional, thought leadership, longer form
    - Reddit: Value-first, community-focused, authentic
    - Blog: Comprehensive, SEO-optimized, actionable

    ## Competitor Intelligence
    #{context.competitor_intel_content || "No competitor intel available"}

    ## Key Themes for This Cycle
    Focus on educational and problem-aware content that demonstrates understanding of customer challenges.
    Include at least one humor variant per content type to test engagement.
    """
  end

  defp query_smart_model_for_brief_rewrite(context, previous_brief) do
    # This is a placeholder - in production, this would call a smart model
    # to rewrite the brief based on performance data
    """
    Content Brief Rewrite for #{context.product_name}

    ## Previous Brief Summary
    #{previous_brief}

    ## Updated Voice Profile
    #{context.voice_profile}

    ## Performance Insights
    [Based on actual performance data - to be expanded when Phase 7 is complete]

    ## Updated Strategy
    Focus on high-performing angles identified from scoreboard data.
    Continue testing humor variants as they historically perform well.
    Prioritize content formats that showed positive delta between predicted and actual engagement.
    """
  end
end