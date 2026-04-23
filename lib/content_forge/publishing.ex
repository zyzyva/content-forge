defmodule ContentForge.Publishing do
  @moduledoc """
  Context for managing publishing operations, including tracking published posts
  and engagement metrics.
  """

  import Ecto.Query, warn: false
  alias ContentForge.Repo
  alias ContentForge.Publishing.PublishedPost
  alias ContentForge.Publishing.EngagementMetric
  alias ContentForge.Publishing.WebhookDelivery
  alias ContentForge.Publishing.VideoJob

  # ============================================
  # Published Posts
  # ============================================

  def list_published_posts(opts \\ []) do
    opts = Keyword.validate!(opts, [:product_id, :platform, :limit])

    PublishedPost
    |> maybe_filter_by_product(Keyword.get(opts, :product_id))
    |> maybe_filter_by_platform(Keyword.get(opts, :platform))
    |> maybe_limit(Keyword.get(opts, :limit, 100))
    |> order_by(desc: :posted_at)
    |> Repo.all()
  end

  def get_published_post(id), do: Repo.get(PublishedPost, id)

  def create_published_post(attrs) do
    %PublishedPost{}
    |> PublishedPost.changeset(attrs)
    |> Repo.insert()
  end

  def update_published_post(%PublishedPost{} = post, attrs) do
    post
    |> PublishedPost.changeset(attrs)
    |> Repo.update()
  end

  def get_post_by_platform_id(platform, platform_post_id) do
    PublishedPost
    |> where(platform: ^platform, platform_post_id: ^platform_post_id)
    |> Repo.one()
  end

  # ============================================
  # Engagement Metrics
  # ============================================

  def get_engagement_metrics(product_id, platform) do
    EngagementMetric
    |> where(product_id: ^product_id, platform: ^platform)
    |> Repo.all()
  end

  def get_optimal_posting_windows(product_id, platform, min_posts \\ 20) do
    # Returns the best hour and day combinations based on historical engagement
    metrics =
      EngagementMetric
      |> where(product_id: ^product_id, platform: ^platform)
      |> where([m], m.total_posts >= ^min_posts)
      |> order_by(desc: :avg_engagement)
      |> Repo.all()

    if metrics == [] do
      # Fallback to default optimal times if insufficient data
      default_optimal_windows(platform)
    else
      Enum.map(
        metrics,
        &%{hour: &1.hour_of_day, day: &1.day_of_week, avg_engagement: &1.avg_engagement}
      )
    end
  end

  def update_engagement_metrics(product_id, platform) do
    # Recalculate metrics based on published posts in the last 30 days
    thirty_days_ago = DateTime.utc_now() |> DateTime.add(-30 * 24 * 3600, :second)

    posts =
      PublishedPost
      |> where(product_id: ^product_id, platform: ^platform)
      |> where([p], p.posted_at >= ^thirty_days_ago)
      |> where([p], not is_nil(p.engagement_data))
      |> Repo.all()

    # Group by hour and day
    grouped =
      Enum.reduce(posts, %{}, fn post, acc ->
        %{hour: hour, day: day} = extract_time_components(post.posted_at)
        engagement = extract_engagement_score(post.engagement_data)

        key = {hour, day}

        Map.update(acc, key, %{posts: 1, engagement: engagement}, fn existing ->
          %{posts: existing.posts + 1, engagement: existing.engagement + engagement}
        end)
      end)

    # Upsert metrics for each slot
    Enum.each(grouped, fn {{hour, day}, data} ->
      attrs = %{
        product_id: product_id,
        platform: platform,
        hour_of_day: hour,
        day_of_week: day,
        total_posts: data.posts,
        total_engagement: data.engagement,
        avg_engagement: data.engagement / data.posts,
        last_calculated_at: DateTime.utc_now()
      }

      # Try to update existing or insert new
      case Repo.get_by(EngagementMetric,
             product_id: product_id,
             platform: platform,
             hour_of_day: hour,
             day_of_week: day
           ) do
        nil ->
          %EngagementMetric{} |> EngagementMetric.changeset(attrs) |> Repo.insert!()

        metric ->
          metric |> EngagementMetric.changeset(attrs) |> Repo.update!()
      end
    end)

    :ok
  end

  # ============================================
  # Webhook Deliveries
  # ============================================

  def list_webhook_deliveries(opts \\ []) do
    opts = Keyword.validate!(opts, [:product_id, :blog_webhook_id, :draft_id, :status, :limit])

    WebhookDelivery
    |> maybe_filter_by_product(Keyword.get(opts, :product_id))
    |> maybe_filter_by_blog_webhook(Keyword.get(opts, :blog_webhook_id))
    |> maybe_filter_by_draft(Keyword.get(opts, :draft_id))
    |> maybe_filter_by_status(Keyword.get(opts, :status))
    |> maybe_limit(Keyword.get(opts, :limit, 100))
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def get_webhook_delivery(id), do: Repo.get(WebhookDelivery, id)

  def create_webhook_delivery(attrs) do
    %WebhookDelivery{}
    |> WebhookDelivery.changeset(attrs)
    |> Repo.insert()
  end

  def update_webhook_delivery(%WebhookDelivery{} = delivery, attrs) do
    delivery
    |> WebhookDelivery.changeset(attrs)
    |> Repo.update()
  end

  def get_pending_webhook_deliveries(blog_webhook_id) do
    WebhookDelivery
    |> where(blog_webhook_id: ^blog_webhook_id, status: "pending")
    |> Repo.all()
  end

  # ============================================
  # Video Jobs
  # ============================================

  def list_video_jobs(opts \\ []) do
    opts = Keyword.validate!(opts, [:product_id, :draft_id, :status, :feature_flag, :limit])

    VideoJob
    |> maybe_filter_by_product(Keyword.get(opts, :product_id))
    |> maybe_filter_by_draft(Keyword.get(opts, :draft_id))
    |> maybe_filter_by_video_status(Keyword.get(opts, :status))
    |> maybe_filter_by_feature_flag(Keyword.get(opts, :feature_flag))
    |> maybe_limit(Keyword.get(opts, :limit, 100))
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def get_video_job(id), do: Repo.get(VideoJob, id)

  def get_video_job_by_draft(draft_id) do
    VideoJob
    |> where(draft_id: ^draft_id)
    |> Repo.one()
  end

  def get_video_job_by_media_forge_job_id(nil), do: nil

  def get_video_job_by_media_forge_job_id(job_id) when is_binary(job_id) do
    Repo.get_by(VideoJob, media_forge_job_id: job_id)
  end

  def create_video_job(attrs) do
    %VideoJob{}
    |> VideoJob.changeset(attrs)
    |> Repo.insert()
  end

  def update_video_job(%VideoJob{} = video_job, attrs) do
    video_job
    |> VideoJob.changeset(attrs)
    |> Repo.update()
  end

  def update_video_job_status(%VideoJob{} = video_job, status, r2_keys) do
    current_keys = video_job.per_step_r2_keys || %{}
    merged_keys = Map.merge(current_keys, r2_keys)

    video_job
    |> VideoJob.status_changeset(%{
      status: status,
      per_step_r2_keys: merged_keys
    })
    |> Repo.update()
  end

  def pause_video_job(%VideoJob{} = video_job, reason) do
    video_job
    |> VideoJob.status_changeset(%{
      status: "paused",
      error: reason
    })
    |> Repo.update()
  end

  def resume_video_job(%VideoJob{} = video_job) do
    video_job
    |> VideoJob.status_changeset(%{
      status: "script_approved",
      error: nil
    })
    |> Repo.update()
  end

  def get_pending_video_jobs do
    VideoJob
    |> where(status: "script_approved")
    |> where(feature_flag: true)
    |> Repo.all()
  end

  defp maybe_filter_by_video_status(query, nil), do: query
  defp maybe_filter_by_video_status(query, status), do: where(query, status: ^status)

  defp maybe_filter_by_feature_flag(query, nil), do: query
  defp maybe_filter_by_feature_flag(query, flag), do: where(query, feature_flag: ^flag)

  # ============================================
  # Helpers
  # ============================================

  defp maybe_filter_by_product(query, nil), do: query
  defp maybe_filter_by_product(query, product_id), do: where(query, product_id: ^product_id)

  defp maybe_filter_by_platform(query, nil), do: query
  defp maybe_filter_by_platform(query, platform), do: where(query, platform: ^platform)

  defp maybe_filter_by_blog_webhook(query, nil), do: query

  defp maybe_filter_by_blog_webhook(query, blog_webhook_id),
    do: where(query, blog_webhook_id: ^blog_webhook_id)

  defp maybe_filter_by_draft(query, nil), do: query
  defp maybe_filter_by_draft(query, draft_id), do: where(query, draft_id: ^draft_id)

  defp maybe_filter_by_status(query, nil), do: query
  defp maybe_filter_by_status(query, status), do: where(query, status: ^status)

  defp maybe_limit(query, limit), do: limit(query, ^limit)

  defp extract_time_components(datetime) do
    hour = datetime.hour
    day = Date.day_of_week(datetime)
    %{hour: hour, day: day}
  end

  defp extract_engagement_score(nil), do: 0

  defp extract_engagement_score(data) when is_map(data) do
    (data["likes"] || 0) + (data["shares"] || 0) * 2 + (data["comments"] || 0) * 3
  end

  defp extract_engagement_score(_), do: 0

  # Default optimal windows for each platform when no data exists
  defp default_optimal_windows("twitter"),
    do: [%{hour: 9, day: 3}, %{hour: 12, day: 3}, %{hour: 17, day: 3}]

  defp default_optimal_windows("linkedin"),
    do: [%{hour: 8, day: 2}, %{hour: 10, day: 3}, %{hour: 12, day: 4}]

  defp default_optimal_windows("reddit"),
    do: [%{hour: 12, day: 6}, %{hour: 15, day: 6}, %{hour: 20, day: 7}]

  defp default_optimal_windows("facebook"),
    do: [%{hour: 11, day: 4}, %{hour: 14, day: 5}, %{hour: 19, day: 6}]

  defp default_optimal_windows("instagram"),
    do: [%{hour: 11, day: 5}, %{hour: 17, day: 5}, %{hour: 19, day: 7}]

  defp default_optimal_windows(_), do: [%{hour: 12, day: 4}]
end
