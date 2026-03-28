defmodule ContentForge.Jobs.MetricsPoller do
  @moduledoc """
  Oban job for polling platform metrics and updating the scoreboard.
  Runs at 24h, 7d, and 30d intervals to track content performance.

  On each run:
  1. Fetches engagement data for published content
  2. Updates scoreboard entries with actual metrics
  3. Labels winners/losers vs rolling average
  4. Updates model calibration data
  5. Triggers engagement spike alerts
  6. Triggers brief rewrite if 5+ poor performers
  """

  use Oban.Worker, max_attempts: 3

  import Ecto.Query

  alias ContentForge.{Metrics, Products}
  alias ContentForge.ContentGeneration.DraftScore
  alias ContentForge.Publishing.PublishedPost
  alias ContentForge.Repo

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"product_id" => product_id, "interval" => interval}}) do
    Logger.info("MetricsPoller: Starting for product #{product_id}, interval #{interval}")

    case Products.get_product(product_id) do
      nil ->
        Logger.error("MetricsPoller: Product not found #{product_id}")
        {:cancel, "Product not found"}

      product ->
        poll_product_metrics(product, interval)
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"product_id" => product_id}}) do
    Logger.info("MetricsPoller: Starting default poll for product #{product_id}")

    case Products.get_product(product_id) do
      nil ->
        {:cancel, "Product not found"}

      product ->
        # Default to 24h interval
        poll_product_metrics(product, "24h")
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "all_products", "interval" => interval}}) do
    Logger.info("MetricsPoller: Polling all products, interval #{interval}")

    products = Products.list_products()

    Enum.each(products, fn product ->
      poll_product_metrics(product, interval)
    end)

    :ok
  end

  defp poll_product_metrics(product, interval) do
    hours = interval_to_hours(interval)

    # Get published posts needing measurement
    published_posts = get_published_posts_for_measurement(product.id, hours)

    Logger.info(
      "MetricsPoller: Found #{length(published_posts)} posts to measure for #{product.name}"
    )

    measured_count =
      Enum.reduce(published_posts, 0, fn post, acc ->
        case measure_and_record_post(product, post) do
          {:ok, _} ->
            acc + 1

          {:error, reason} ->
            Logger.warning("MetricsPoller: Failed to measure post #{post.id}: #{reason}")
            acc
        end
      end)

    Logger.info("MetricsPoller: Measured #{measured_count} posts for #{product.name}")

    # Check for clip flags on YouTube videos
    measure_youtube_clips(product.id)

    # Check if we need to trigger a brief rewrite
    check_rewrite_trigger(product)

    {:ok, %{measured: measured_count, interval: interval}}
  end

  defp interval_to_hours("24h"), do: 24
  defp interval_to_hours("7d"), do: 168
  defp interval_to_hours("30d"), do: 720
  defp interval_to_hours(_), do: 24

  defp get_published_posts_for_measurement(product_id, hours) do
    cutoff = DateTime.utc_now() |> DateTime.add(-hours * 3600, :second)

    PublishedPost
    |> where(product_id: ^product_id)
    |> where([p], p.posted_at <= ^cutoff)
    |> where([p], not is_nil(p.engagement_data))
    |> preload([:draft])
    |> Repo.all()
  end

  defp measure_and_record_post(product, %PublishedPost{} = post) do
    # Extract engagement score from platform data
    engagement = extract_engagement(post.engagement_data, post.platform)

    if engagement > 0 do
      draft = post.draft

      # Get or create scoreboard entry
      scoreboard_entry =
        case Metrics.get_scoreboard_for_draft(post.draft_id) do
          nil when draft != nil ->
            # Create new entry from draft scores
            composite_score = calculate_composite_from_draft(draft.id)
            model_scores = get_model_scores(draft.id)

            {:ok, entry} =
              Metrics.create_scoreboard_entry(%{
                content_id: draft.id,
                product_id: post.product_id,
                platform: post.platform,
                angle: draft.angle,
                format: draft.content_type,
                composite_ai_score: composite_score,
                per_model_scores: model_scores,
                draft_id: draft.id,
                measured_at: DateTime.utc_now()
              })

            entry

          entry when entry != nil ->
            entry

          _ ->
            nil
        end

      if scoreboard_entry do
        # Update with actual engagement
        {:ok, updated_entry} = Metrics.measure_and_update_scoreboard(scoreboard_entry, engagement)

        # Update model calibration
        if updated_entry.per_model_scores do
          Metrics.update_model_calibration(updated_entry, updated_entry.per_model_scores)
        end

        # Check for engagement spike
        if updated_entry.outcome == "winner" && updated_entry.delta > 3.0 do
          trigger_spike_alert(product, updated_entry)
        end

        {:ok, updated_entry}
      else
        {:error, :no_scoreboard_entry}
      end
    else
      {:error, :no_engagement_data}
    end
  end

  defp extract_engagement(nil, _), do: 0

  defp extract_engagement(data, platform) when is_map(data) do
    # Platform-specific extraction
    case platform do
      "youtube" ->
        (data["views"] || 0) + (data["likes"] || 0) * 2 + (data["comments"] || 0) * 5 +
          (data["shares"] || 0) * 3

      "twitter" ->
        (data["likes"] || 0) + (data["retweets"] || 0) * 3 + (data["replies"] || 0) * 2

      "linkedin" ->
        (data["likes"] || 0) + (data["comments"] || 0) * 3 + (data["shares"] || 0) * 2

      "reddit" ->
        (data["upvotes"] || 0) + (data["downvotes"] || 0) + (data["comments"] || 0) * 5

      "facebook" ->
        (data["likes"] || 0) + (data["comments"] || 0) * 3 + (data["shares"] || 0) * 2

      "instagram" ->
        (data["likes"] || 0) + (data["comments"] || 0) * 3 + (data["saves"] || 0) * 2

      _ ->
        # Generic fallback
        data
        |> Map.values()
        |> Enum.filter(&is_integer/1)
        |> Enum.sum()
    end
  end

  defp extract_engagement(_, _), do: 0

  defp calculate_composite_from_draft(draft_id) do
    scores =
      DraftScore
      |> where(draft_id: ^draft_id)
      |> Repo.all()

    if scores == [] do
      nil
    else
      score_values = Enum.map(scores, & &1.composite_score)
      Enum.sum(score_values) / length(score_values)
    end
  end

  defp get_model_scores(draft_id) do
    DraftScore
    |> where(draft_id: ^draft_id)
    |> Repo.all()
    |> Enum.reduce(%{}, fn score, acc ->
      Map.put(acc, score.model_name, score.composite_score)
    end)
  end

  defp measure_youtube_clips(product_id) do
    # Get YouTube posts that might have retention data
    youtube_posts =
      PublishedPost
      |> where(product_id: ^product_id)
      |> where(platform: "youtube")
      |> where([p], not is_nil(p.engagement_data))
      |> Repo.all()

    Enum.each(youtube_posts, fn post ->
      # Check if retention data exists in engagement_data
      retention_data = post.engagement_data["retention_curve"]

      if retention_data do
        video_id = post.platform_post_id

        case ContentForge.Metrics.ClipFlag.from_youtube_retention(
               post.draft_id,
               video_id,
               retention_data
             ) do
          {:ok, flags} ->
            Enum.each(flags, fn flag ->
              Metrics.create_clip_flag(Map.from_struct(flag))
            end)

          {:error, _} ->
            nil
        end
      end
    end)
  end

  defp check_rewrite_trigger(product) do
    platforms = ~w(twitter linkedin reddit facebook instagram youtube)

    Enum.each(platforms, fn platform ->
      if Metrics.should_trigger_rewrite?(product.id, platform, 7) do
        Logger.warning(
          "MetricsPoller: Triggering rewrite for #{product.name} on #{platform} - 5+ poor performers detected"
        )

        trigger_rewrite_alert(product, platform)
      end
    end)
  end

  defp trigger_spike_alert(product, entry) do
    Logger.info(
      "MetricsPoller: Engagement spike detected for #{product.name} - " <>
        "platform: #{entry.platform}, delta: #{entry.delta}, engagement: #{entry.actual_engagement_score}"
    )

    # Could integrate with notification system here
    # For now just log - the comment flagging is handled by flagging for review
  end

  defp trigger_rewrite_alert(product, platform) do
    Logger.warning("MetricsPoller: Rewrite needed for #{product.name} on #{platform}")

    # Could trigger a content brief regeneration job here
    # For now just log
  end
end
