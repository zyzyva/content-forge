defmodule ContentForge.Jobs.PublishingScheduler do
  @moduledoc """
  Oban job for scheduling posts across all products and platforms.
  Runs periodically and creates Publisher jobs for each product/platform
  that needs to post based on their cadence and optimal timing.
  """

  use Oban.Worker, max_attempts: 1

  alias ContentForge.{Products, Publishing}

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: _args}) do
    Logger.info("PublishingScheduler: Running scheduled publishing check")

    # Get all products
    products = Products.list_products()

    Enum.each(products, fn product ->
      schedule_product_posts(product)
    end)

    :ok
  end

  defp schedule_product_posts(product) do
    publishing_targets = product.publishing_targets || %{}

    platforms = ["twitter", "linkedin", "reddit", "facebook", "instagram"]

    Enum.each(platforms, fn platform ->
      platform_config = Map.get(publishing_targets, platform)

      if platform_config && platform_config["enabled"] do
        # Check if we should post based on cadence
        cadence = platform_config["cadence"] || "3x/week"
        should_post = should_post?(product.id, platform, cadence)

        if should_post do
          # Get optimal posting windows
          optimal_windows = Publishing.get_optimal_posting_windows(product.id, platform)

          # Schedule the post
          schedule_at_optimal_time(product.id, platform, optimal_windows)

          Logger.info(
            "PublishingScheduler: Scheduled post for product #{product.id}, platform #{platform}"
          )
        end
      end
    end)
  end

  defp should_post?(product_id, platform, cadence) do
    # Parse cadence (e.g., "3x/week", "1x/day", "1x/month")
    {posts_per_period, period} = parse_cadence(cadence)

    # Get recent posts for this product and platform
    since = since_period(period)

    recent_posts =
      Publishing.list_published_posts(product_id: product_id, platform: platform, limit: 100)

    recent_posts =
      Enum.filter(recent_posts, fn post ->
        post.posted_at && DateTime.compare(post.posted_at, since) == :gt
      end)

    # Check if we should post
    case period do
      "day" ->
        length(recent_posts) < posts_per_period

      "week" ->
        # Check if there's a post in the current week
        now = DateTime.utc_now()
        week_start = DateTime.new!(Date.beginning_of_week(now, :sunday), ~T[00:00:00], "Etc/UTC")

        week_posts =
          Enum.filter(recent_posts, fn post ->
            post.posted_at && DateTime.compare(post.posted_at, week_start) == :gt
          end)

        length(week_posts) < posts_per_period

      "month" ->
        now = DateTime.utc_now()
        month_start = DateTime.new!(Date.beginning_of_month(now), ~T[00:00:00], "Etc/UTC")

        month_posts =
          Enum.filter(recent_posts, fn post ->
            post.posted_at && DateTime.compare(post.posted_at, month_start) == :gt
          end)

        length(month_posts) < posts_per_period

      _ ->
        true
    end
  end

  defp parse_cadence(cadence) do
    case Regex.run(~r/(\d+)x\/(day|week|month)/, cadence) do
      [_, count, period] ->
        {String.to_integer(count), period}

      _ ->
        # Default
        {1, "week"}
    end
  end

  defp since_period("day"), do: DateTime.utc_now() |> DateTime.add(-1, :day)
  defp since_period("week"), do: DateTime.utc_now() |> DateTime.add(-7, :day)
  defp since_period("month"), do: DateTime.utc_now() |> DateTime.add(-30, :day)
  defp since_period(_), do: DateTime.utc_now() |> DateTime.add(-7, :day)

  defp schedule_at_optimal_time(product_id, platform, optimal_windows) do
    # Get current time
    now = DateTime.utc_now()
    current_hour = now.hour
    current_day = Date.day_of_week(now)

    # Find the next optimal window that's in the future
    {next_hour, next_day} = find_next_window(optimal_windows, current_hour, current_day)

    # Calculate delay in seconds until the optimal time
    delay = calculate_delay_until(next_hour, next_day, now)

    # Schedule the job
    Oban.insert(
      %{
        "product_id" => product_id,
        "platform" => platform
      },
      scheduled_at: DateTime.add(now, delay, :second)
    )
  end

  defp find_next_window(windows, current_hour, current_day) do
    # Sort windows by day then hour to find the next one
    sorted = Enum.sort_by(windows, fn w -> {w.day, w.hour} end)

    # Find the first window that's in the future
    found =
      Enum.find(sorted, fn w ->
        w.day > current_day || (w.day == current_day && w.hour > current_hour)
      end)

    case found do
      nil ->
        # Wrap around to the first window (next day)
        first = List.first(sorted)
        {first.hour, first.day}

      window ->
        {window.hour, window.day}
    end
  end

  defp calculate_delay_until(target_hour, target_day, now) do
    current_day = Date.day_of_week(now)
    current_hour = now.hour

    days_ahead =
      cond do
        target_day > current_day -> target_day - current_day
        target_day == current_day -> 0
        true -> 7 - current_day + target_day
      end

    hours_ahead =
      if days_ahead == 0 do
        max(0, target_hour - current_hour)
      else
        target_hour
      end

    days_ahead * 24 * 3600 + hours_ahead * 3600
  end
end
