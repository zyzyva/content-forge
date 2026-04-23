defmodule ContentForge.Jobs.MetricsPoller do
  @moduledoc """
  Oban job for polling platform metrics and updating the scoreboard.
  Runs at 24h, 7d, and 30d intervals to track content performance.

  On each run:
  1. Fetches engagement data from each platform API for published posts
  2. Updates PublishedPost.engagement_data with live metrics
  3. Updates scoreboard entries with actual engagement scores
  4. Labels winners/losers vs rolling average
  5. Updates model calibration data
  6. Enqueues WinnerRepurposingEngine for engagement spikes
  7. Enqueues ContentBriefGenerator (force_rewrite) when 5+ poor performers detected
  """

  use Oban.Worker, max_attempts: 3

  import Ecto.Query

  alias ContentForge.{Metrics, Products, Publishing}
  alias ContentForge.ContentGeneration.DraftScore
  alias ContentForge.Metrics.ScoreboardEntry
  alias ContentForge.Publishing.PublishedPost
  alias ContentForge.Publishing.{Twitter, LinkedIn, Facebook, Reddit, YouTube}
  alias ContentForge.Repo

  require Logger

  # Don't re-measure posts older than this
  @max_age_days 90

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
        poll_product_metrics(product, "24h")
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "all_products", "interval" => interval}}) do
    Logger.info("MetricsPoller: Polling all products, interval #{interval}")

    Enum.each(Products.list_products(), fn product ->
      poll_product_metrics(product, interval)
    end)

    :ok
  end

  defp poll_product_metrics(product, interval) do
    hours = interval_to_hours(interval)
    published_posts = get_published_posts_for_measurement(product.id, hours)

    Logger.info(
      "MetricsPoller: Found #{length(published_posts)} posts to measure for #{product.name}"
    )

    measured_count =
      Enum.reduce(published_posts, 0, fn post, acc ->
        case fetch_and_update_engagement(post, product) do
          {:ok, updated_post} ->
            case measure_and_record_post(product, updated_post) do
              {:ok, _} ->
                acc + 1

              {:error, reason} ->
                Logger.warning(
                  "MetricsPoller: Failed to record post #{post.id}: #{inspect(reason)}"
                )

                acc
            end

          {:error, reason} ->
            Logger.warning(
              "MetricsPoller: Failed to fetch metrics for post #{post.id}: #{inspect(reason)}"
            )

            acc
        end
      end)

    Logger.info("MetricsPoller: Measured #{measured_count} posts for #{product.name}")

    measure_youtube_clips(product.id)
    check_rewrite_trigger(product)

    {:ok, %{measured: measured_count, interval: interval}}
  end

  defp interval_to_hours("24h"), do: 24
  defp interval_to_hours("7d"), do: 168
  defp interval_to_hours("30d"), do: 720
  defp interval_to_hours(_), do: 24

  # Posts published at least `hours` ago, at most @max_age_days old
  defp get_published_posts_for_measurement(product_id, hours) do
    cutoff = DateTime.utc_now() |> DateTime.add(-hours * 3600, :second)
    max_age = DateTime.utc_now() |> DateTime.add(-@max_age_days * 24 * 3600, :second)

    PublishedPost
    |> where(product_id: ^product_id)
    |> where([p], p.posted_at <= ^cutoff)
    |> where([p], p.posted_at >= ^max_age)
    |> preload([:draft])
    |> Repo.all()
  end

  # Fetch live metrics from the platform and update PublishedPost.engagement_data.
  # Returns {:ok, updated_post} or {:error, reason}.
  defp fetch_and_update_engagement(%PublishedPost{platform_post_id: nil} = post, _product) do
    Logger.warning("MetricsPoller: Post #{post.id} has no platform_post_id, skipping")
    {:error, :no_platform_post_id}
  end

  defp fetch_and_update_engagement(post, product) do
    case fetch_platform_metrics(post, product) do
      {:ok, metrics} ->
        case Publishing.update_published_post(post, %{engagement_data: metrics}) do
          {:ok, updated_post} -> {:ok, updated_post}
          {:error, changeset} -> {:error, changeset}
        end

      {:error, :no_credentials} ->
        Logger.warning(
          "MetricsPoller: No credentials for #{post.platform}, skipping post #{post.id}"
        )

        {:error, :no_credentials}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_platform_metrics(%PublishedPost{platform: "twitter"} = post, product) do
    case get_credentials(product, "twitter") do
      nil -> {:error, :no_credentials}
      creds -> Twitter.fetch_metrics(post.platform_post_id, creds)
    end
  end

  defp fetch_platform_metrics(%PublishedPost{platform: "linkedin"} = post, product) do
    case get_credentials(product, "linkedin") do
      nil -> {:error, :no_credentials}
      creds -> LinkedIn.fetch_metrics(post.platform_post_id, creds)
    end
  end

  defp fetch_platform_metrics(%PublishedPost{platform: "facebook"} = post, product) do
    case get_credentials(product, "facebook") do
      nil -> {:error, :no_credentials}
      creds -> Facebook.fetch_metrics(post.platform_post_id, creds)
    end
  end

  defp fetch_platform_metrics(%PublishedPost{platform: "instagram"} = post, product) do
    case get_credentials(product, "instagram") do
      nil -> {:error, :no_credentials}
      creds -> Facebook.fetch_instagram_metrics(post.platform_post_id, creds)
    end
  end

  defp fetch_platform_metrics(%PublishedPost{platform: "reddit"} = post, product) do
    case get_credentials(product, "reddit") do
      nil -> {:error, :no_credentials}
      creds -> Reddit.fetch_metrics(post.platform_post_id, creds)
    end
  end

  defp fetch_platform_metrics(%PublishedPost{platform: "youtube"} = post, product) do
    case get_credentials(product, "youtube") do
      nil -> {:error, :no_credentials}
      creds -> YouTube.fetch_metrics(post.platform_post_id, creds)
    end
  end

  defp fetch_platform_metrics(%PublishedPost{platform: platform} = post, _product) do
    Logger.warning("MetricsPoller: No metrics fetcher for platform #{platform}, post #{post.id}")
    {:error, :unsupported_platform}
  end

  defp get_credentials(product, "twitter") do
    config = (product.publishing_targets || %{})["twitter"] || %{}

    if config["enabled"] && config["access_token"] && config["api_key"] do
      %{twitter_access_token: config["access_token"], twitter_api_key: config["api_key"]}
    end
  end

  defp get_credentials(product, "linkedin") do
    config = (product.publishing_targets || %{})["linkedin"] || %{}

    if config["enabled"] && config["access_token"] && config["person_id"] do
      %{linkedin_access_token: config["access_token"], linkedin_person_id: config["person_id"]}
    end
  end

  defp get_credentials(product, "facebook") do
    config = (product.publishing_targets || %{})["facebook"] || %{}

    if config["enabled"] && config["access_token"] && config["page_id"] do
      %{facebook_access_token: config["access_token"], facebook_page_id: config["page_id"]}
    end
  end

  defp get_credentials(product, "instagram") do
    config = (product.publishing_targets || %{})["instagram"] || %{}

    if config["enabled"] && config["access_token"] && config["account_id"] do
      %{facebook_access_token: config["access_token"], instagram_account_id: config["account_id"]}
    end
  end

  defp get_credentials(product, "reddit") do
    config = (product.publishing_targets || %{})["reddit"] || %{}

    if config["enabled"] && config["access_token"] do
      %{reddit_access_token: config["access_token"]}
    end
  end

  defp get_credentials(product, "youtube") do
    config = (product.publishing_targets || %{})["youtube"] || %{}

    if config["enabled"] && config["access_token"] do
      %{youtube_access_token: config["access_token"]}
    end
  end

  defp get_credentials(_product, _platform), do: nil

  defp measure_and_record_post(product, %PublishedPost{} = post) do
    engagement = extract_engagement(post.engagement_data, post.platform)

    if engagement > 0 do
      draft = post.draft

      scoreboard_entry =
        case Metrics.get_scoreboard_for_draft(post.draft_id) do
          nil when draft != nil ->
            composite_score = calculate_composite_from_draft(draft.id)
            model_scores = get_model_scores(draft.id)

            case Metrics.create_scoreboard_entry(%{
                   content_id: draft.id,
                   product_id: post.product_id,
                   platform: post.platform,
                   angle: draft.angle,
                   format: draft.content_type,
                   composite_ai_score: composite_score,
                   per_model_scores: model_scores,
                   draft_id: draft.id,
                   measured_at: DateTime.utc_now()
                 }) do
              {:ok, entry} ->
                entry

              {:error, changeset} ->
                Logger.error(
                  "MetricsPoller: Failed to create scoreboard entry for draft #{draft.id}: #{inspect(changeset.errors)}"
                )

                nil
            end

          entry when entry != nil ->
            entry

          _ ->
            nil
        end

      if scoreboard_entry do
        {:ok, updated_entry} = Metrics.measure_and_update_scoreboard(scoreboard_entry, engagement)

        if updated_entry.per_model_scores do
          Metrics.update_model_calibration(updated_entry, updated_entry.per_model_scores)
        end

        maybe_trigger_spike(product, updated_entry)

        {:ok, updated_entry}
      else
        {:error, :no_scoreboard_entry}
      end
    else
      {:error, :no_engagement_data}
    end
  end

  defp extract_engagement(nil, _), do: 0

  defp extract_engagement(data, "youtube") when is_map(data) do
    (data["views"] || 0) + (data["likes"] || 0) * 2 + (data["comments"] || 0) * 5
  end

  defp extract_engagement(data, "twitter") when is_map(data) do
    (data["likes"] || 0) + (data["retweets"] || 0) * 3 + (data["replies"] || 0) * 2
  end

  defp extract_engagement(data, platform)
       when is_map(data) and platform in ["linkedin", "facebook"] do
    (data["likes"] || 0) + (data["comments"] || 0) * 3 + (data["shares"] || 0) * 2
  end

  defp extract_engagement(data, "instagram") when is_map(data) do
    (data["likes"] || 0) + (data["comments"] || 0) * 3
  end

  defp extract_engagement(data, "reddit") when is_map(data) do
    (data["score"] || 0) + (data["comments"] || 0) * 5
  end

  defp extract_engagement(data, _platform) when is_map(data) do
    data
    |> Map.values()
    |> Enum.filter(&is_integer/1)
    |> Enum.sum()
  end

  defp extract_engagement(_, _), do: 0

  defp calculate_composite_from_draft(draft_id) do
    scores =
      DraftScore
      |> where(draft_id: ^draft_id)
      |> Repo.all()

    case scores do
      [] ->
        nil

      _ ->
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
    PublishedPost
    |> where(product_id: ^product_id)
    |> where(platform: "youtube")
    |> where([p], not is_nil(p.engagement_data))
    |> Repo.all()
    |> Enum.each(fn post ->
      retention_data = post.engagement_data["retention_curve"]

      if retention_data && retention_data != [] do
        case ContentForge.Metrics.ClipFlag.from_youtube_retention(
               post.draft_id,
               post.platform_post_id,
               retention_data
             ) do
          {:ok, flags} ->
            Enum.each(flags, fn flag ->
              Metrics.create_clip_flag(Map.from_struct(flag))
            end)

          {:error, _} ->
            :ok
        end
      end
    end)
  end

  @doc """
  Checks every platform for poor-performer thresholds and enqueues a
  brief-rewrite job when at least five scoreboard entries have
  `delta < -1.0` within the configured window.

  Public so the auto-trigger behaviour can be asserted by tests; it is
  also called at the end of each poll from `poll_product_metrics/2`.
  Enqueued jobs are idempotent per `product_id`: Oban's `unique` config
  collapses duplicate rewrite requests so repeat polls do not stack up
  multiple rewrites for the same state transition.
  """
  def check_rewrite_trigger(product) do
    platforms = ~w(twitter linkedin reddit facebook instagram youtube)

    Enum.each(platforms, fn platform ->
      if Metrics.should_trigger_rewrite?(product.id, platform, 7) do
        Logger.warning(
          "MetricsPoller: Triggering brief rewrite for #{product.name} on #{platform}"
        )

        trigger_rewrite(product)
      end
    end)
  end

  @doc """
  Enqueues `WinnerRepurposingEngine` when a scoreboard entry's outcome
  is `"winner"` and its delta strictly exceeds 3.0.

  Public so the auto-trigger behaviour can be asserted by tests; it is
  also called from `measure_and_record_post/2` after
  `Metrics.measure_and_update_scoreboard/2` lands the measurement.
  Enqueued jobs are idempotent per `draft_id`: Oban's `unique` config
  prevents duplicate repurposing for the same winning draft.
  """
  def maybe_trigger_spike(product, %ScoreboardEntry{outcome: "winner", delta: delta} = entry)
      when is_number(delta) and delta > 3.0 do
    trigger_spike_alert(product, entry)
  end

  def maybe_trigger_spike(_product, _entry), do: :noop

  defp trigger_spike_alert(product, entry) do
    Logger.info(
      "MetricsPoller: Engagement spike for #{product.name} - " <>
        "platform: #{entry.platform}, delta: #{entry.delta}"
    )

    %{"draft_id" => entry.draft_id}
    |> ContentForge.Jobs.WinnerRepurposingEngine.new(
      unique: [period: :infinity, fields: [:args, :worker]]
    )
    |> Oban.insert()
  end

  defp trigger_rewrite(product) do
    Logger.warning("MetricsPoller: Enqueueing brief rewrite for #{product.name}")

    # Idempotency: repeat polls in the same day for the same product
    # collapse to a single rewrite job. force_rewrite is held constant so
    # duplicate arg maps compare equal.
    %{"product_id" => product.id, "force_rewrite" => true}
    |> ContentForge.Jobs.ContentBriefGenerator.new(
      unique: [period: 24 * 60 * 60, fields: [:args, :worker]]
    )
    |> Oban.insert()
  end
end
