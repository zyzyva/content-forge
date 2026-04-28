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
  alias ContentForge.Jobs.CompetitorIntelSynthesizer
  alias ContentForge.Jobs.ContentBriefGenerator
  alias ContentForge.Jobs.WinnerRepurposingEngine
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
      creds -> Twitter.fetch_metrics(post.platform_post_id, post.platform_post_url, creds)
    end
  end

  defp fetch_platform_metrics(%PublishedPost{platform: "linkedin"} = post, product) do
    case get_credentials(product, "linkedin") do
      nil -> {:error, :no_credentials}
      creds -> LinkedIn.fetch_metrics(post.platform_post_id, post.platform_post_url, creds)
    end
  end

  defp fetch_platform_metrics(%PublishedPost{platform: "facebook"} = post, product) do
    case get_credentials(product, "facebook") do
      nil -> {:error, :no_credentials}
      creds -> Facebook.fetch_metrics(post.platform_post_id, post.platform_post_url, creds)
    end
  end

  defp fetch_platform_metrics(%PublishedPost{platform: "instagram"} = post, product) do
    case get_credentials(product, "instagram") do
      nil ->
        {:error, :no_credentials}

      creds ->
        Facebook.fetch_instagram_metrics(post.platform_post_id, post.platform_post_url, creds)
    end
  end

  defp fetch_platform_metrics(%PublishedPost{platform: "reddit"} = post, product) do
    case get_credentials(product, "reddit") do
      nil -> {:error, :no_credentials}
      creds -> Reddit.fetch_metrics(post.platform_post_id, post.platform_post_url, creds)
    end
  end

  defp fetch_platform_metrics(%PublishedPost{platform: "youtube"} = post, product) do
    case get_credentials(product, "youtube") do
      nil -> {:error, :no_credentials}
      creds -> YouTube.fetch_metrics(post.platform_post_id, post.platform_post_url, creds)
    end
  end

  defp fetch_platform_metrics(%PublishedPost{platform: platform} = post, _product) do
    Logger.warning("MetricsPoller: No metrics fetcher for platform #{platform}, post #{post.id}")
    {:error, :unsupported_platform}
  end

  # Phase 17.7: when a platform is enabled but the per-product
  # OAuth credentials are absent, return an empty map (`%{}`) so
  # the platform module's `fetch_metrics/3` can dispatch through
  # the Apify path. When OAuth IS present, return the credentials
  # map so the existing native API path is preserved (no
  # behavior regression for products that have done the OAuth
  # grind already). Disabled or missing config still returns nil
  # so the poller skips the platform entirely.
  defp get_credentials(product, "twitter") do
    config = (product.publishing_targets || %{})["twitter"] || %{}
    twitter_credentials_for(config)
  end

  defp get_credentials(product, "linkedin") do
    config = (product.publishing_targets || %{})["linkedin"] || %{}
    linkedin_credentials_for(config)
  end

  defp get_credentials(product, "facebook") do
    config = (product.publishing_targets || %{})["facebook"] || %{}
    facebook_credentials_for(config)
  end

  defp get_credentials(product, "instagram") do
    config = (product.publishing_targets || %{})["instagram"] || %{}
    instagram_credentials_for(config)
  end

  defp get_credentials(product, "reddit") do
    config = (product.publishing_targets || %{})["reddit"] || %{}
    reddit_credentials_for(config)
  end

  defp get_credentials(product, "youtube") do
    config = (product.publishing_targets || %{})["youtube"] || %{}
    youtube_credentials_for(config)
  end

  defp get_credentials(_product, _platform), do: nil

  defp twitter_credentials_for(%{"enabled" => true, "access_token" => tok, "api_key" => key})
       when is_binary(tok) and tok != "" and is_binary(key) and key != "" do
    %{twitter_access_token: tok, twitter_api_key: key}
  end

  defp twitter_credentials_for(%{"enabled" => true}), do: %{}
  defp twitter_credentials_for(_), do: nil

  defp linkedin_credentials_for(%{
         "enabled" => true,
         "access_token" => tok,
         "person_id" => pid
       })
       when is_binary(tok) and tok != "" and is_binary(pid) and pid != "" do
    %{linkedin_access_token: tok, linkedin_person_id: pid}
  end

  defp linkedin_credentials_for(%{"enabled" => true}), do: %{}
  defp linkedin_credentials_for(_), do: nil

  defp facebook_credentials_for(%{
         "enabled" => true,
         "access_token" => tok,
         "page_id" => pid
       })
       when is_binary(tok) and tok != "" and is_binary(pid) and pid != "" do
    %{facebook_access_token: tok, facebook_page_id: pid}
  end

  defp facebook_credentials_for(%{"enabled" => true}), do: %{}
  defp facebook_credentials_for(_), do: nil

  defp instagram_credentials_for(%{
         "enabled" => true,
         "access_token" => tok,
         "account_id" => aid
       })
       when is_binary(tok) and tok != "" and is_binary(aid) and aid != "" do
    %{facebook_access_token: tok, instagram_account_id: aid}
  end

  defp instagram_credentials_for(%{"enabled" => true}), do: %{}
  defp instagram_credentials_for(_), do: nil

  defp reddit_credentials_for(%{"enabled" => true, "access_token" => tok})
       when is_binary(tok) and tok != "" do
    %{reddit_access_token: tok}
  end

  defp reddit_credentials_for(%{"enabled" => true}), do: %{}
  defp reddit_credentials_for(_), do: nil

  defp youtube_credentials_for(%{"enabled" => true, "access_token" => tok})
       when is_binary(tok) and tok != "" do
    %{youtube_access_token: tok}
  end

  defp youtube_credentials_for(%{"enabled" => true}), do: %{}
  defp youtube_credentials_for(_), do: nil

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

  # Phase 17.7 unified shape: Apify path returns
  # `%{"likes", "comments", "shares", "views"}` across platforms.
  # Native OAuth paths still emit platform-specific keys
  # (twitter: retweets/replies; reddit: score/upvotes), so each
  # extract_engagement clause prefers unified keys with legacy
  # keys as fallback to preserve the existing scoring weights.

  defp extract_engagement(data, "youtube") when is_map(data) do
    (data["views"] || 0) + (data["likes"] || 0) * 2 + (data["comments"] || 0) * 5
  end

  defp extract_engagement(data, "twitter") when is_map(data) do
    (data["likes"] || 0) +
      (data["shares"] || data["retweets"] || 0) * 3 +
      (data["comments"] || data["replies"] || 0) * 2
  end

  defp extract_engagement(data, platform)
       when is_map(data) and platform in ["linkedin", "facebook"] do
    (data["likes"] || 0) + (data["comments"] || 0) * 3 + (data["shares"] || 0) * 2
  end

  defp extract_engagement(data, "instagram") when is_map(data) do
    (data["likes"] || 0) + (data["comments"] || 0) * 3
  end

  defp extract_engagement(data, "reddit") when is_map(data) do
    (data["score"] || data["likes"] || 0) + (data["comments"] || 0) * 5
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
  Phase 17.6 corrective loop: checks every platform for the
  two-condition external trigger and enqueues a week-windowed
  competitor-intel synthesis followed by a brief regeneration
  when both conditions are met.

  Conditions (in the same 7-day window):

    1. Internal drop: at least 5 scoreboard entries on this
       platform have `delta < -1.0`
       (`Metrics.should_trigger_rewrite?/3`).
    2. Competitor wins: at least one tracked competitor account
       has a post in the window with `engagement_score > 1.0`
       (above their own rolling average,
       `Metrics.competitor_wins_in_window?/2`).

  Other combinations are no-ops:

    * Internal drop alone is treated as noise; we are not the
      only signal in the world.
    * Competitor wins alone are normal corpus refresh material
      (the synthesizer cron handles those independently).

  Public so the auto-trigger behaviour can be asserted by
  tests; also called at the end of each poll from
  `poll_product_metrics/2`. Enqueued jobs are idempotent per
  `product_id` via Oban's `unique` config so repeat polls do
  not stack up duplicate corrective syntheses.
  """
  def check_rewrite_trigger(product) do
    platforms = ~w(twitter linkedin reddit facebook instagram youtube)
    competitor_wins = Metrics.competitor_wins_in_window?(product.id, 7)

    Enum.each(platforms, fn platform ->
      cond do
        not Metrics.should_trigger_rewrite?(product.id, platform, 7) ->
          :noop

        not competitor_wins ->
          Logger.info(
            "MetricsPoller: internal drop on #{platform} for #{product.name} but no competitor wins; treating as noise"
          )

          :noop

        true ->
          Logger.warning(
            "MetricsPoller: corrective trigger for #{product.name} on #{platform} (drop + competitor wins)"
          )

          trigger_corrective_loop(product)
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
    |> WinnerRepurposingEngine.new(unique: [period: :infinity, fields: [:args, :worker]])
    |> Oban.insert()
  end

  defp trigger_corrective_loop(product) do
    # Step 1: enqueue a week-windowed competitor-intel synthesis
    # so the brief regeneration that follows reads fresh
    # corrective intel, not all-time top posts. The synthesizer
    # also resolves any pending_intel_syntheses rows for the
    # matching (product, "week") pair on success (Phase 17.4).
    %{"product_id" => product.id, "window" => "week"}
    |> CompetitorIntelSynthesizer.new(unique: [period: 24 * 60 * 60, fields: [:args, :worker]])
    |> Oban.insert()

    # Step 2: enqueue the brief regeneration. Oban does not
    # enforce ordering, but the brief generator reads whatever
    # intel exists at run time; a stale prior intel is acceptable
    # as a fallback if the synthesizer has not completed yet.
    %{"product_id" => product.id, "force_rewrite" => true}
    |> ContentBriefGenerator.new(unique: [period: 24 * 60 * 60, fields: [:args, :worker]])
    |> Oban.insert()
  end
end
