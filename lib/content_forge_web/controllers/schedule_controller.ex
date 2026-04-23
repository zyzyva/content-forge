defmodule ContentForgeWeb.ScheduleController do
  use ContentForgeWeb, :controller

  alias ContentForge.Jobs.Publisher
  alias ContentForge.{Products, Publishing}

  action_fallback ContentForgeWeb.FallbackController

  # POST /api/v1/products/:id/schedule
  def schedule(conn, %{"product_id" => product_id}) do
    case Products.get_product(product_id) do
      nil ->
        {:error, :not_found}

      product ->
        # Get platforms to schedule from request or use all enabled
        platforms = get_platforms_from_request(conn)

        results =
          Enum.map(platforms, fn platform ->
            schedule_for_platform(product, platform)
          end)

        json(conn, %{
          product_id: product_id,
          scheduled: results
        })
    end
  end

  # GET /api/v1/products/:id/schedule
  def get_schedule(conn, %{"product_id" => product_id}) do
    case Products.get_product(product_id) do
      nil ->
        {:error, :not_found}

      product ->
        publishing_targets = product.publishing_targets || %{}

        platforms = ["twitter", "linkedin", "reddit", "facebook", "instagram"]

        schedule_info =
          Enum.map(platforms, fn platform ->
            platform_config = Map.get(publishing_targets, platform)

            if platform_config && platform_config["enabled"] do
              optimal_windows = Publishing.get_optimal_posting_windows(product_id, platform)
              cadence = platform_config["cadence"] || "3x/week"

              %{
                platform: platform,
                enabled: true,
                cadence: cadence,
                optimal_windows: optimal_windows
              }
            else
              %{platform: platform, enabled: false}
            end
          end)

        json(conn, %{
          product_id: product_id,
          schedule: schedule_info
        })
    end
  end

  # GET /api/v1/products/:id/engagement-metrics
  def get_engagement_metrics(conn, %{"product_id" => product_id}) do
    case Products.get_product(product_id) do
      nil ->
        {:error, :not_found}

      _product ->
        platforms = ["twitter", "linkedin", "reddit", "facebook", "instagram"]

        metrics =
          Enum.map(platforms, fn platform ->
            windows = Publishing.get_engagement_metrics(product_id, platform)

            %{
              platform: platform,
              windows:
                Enum.map(windows, fn w ->
                  %{
                    hour_of_day: w.hour_of_day,
                    day_of_week: w.day_of_week,
                    total_posts: w.total_posts,
                    avg_engagement: w.avg_engagement
                  }
                end)
            }
          end)

        json(conn, %{
          product_id: product_id,
          metrics: metrics
        })
    end
  end

  # POST /api/v1/products/:id/engagement-metrics/refresh
  def refresh_engagement_metrics(conn, %{"product_id" => product_id}) do
    case Products.get_product(product_id) do
      nil ->
        {:error, :not_found}

      _product ->
        platforms = ["twitter", "linkedin", "reddit", "facebook", "instagram"]

        Enum.each(platforms, fn platform ->
          Publishing.update_engagement_metrics(product_id, platform)
        end)

        json(conn, %{
          status: "refreshed",
          product_id: product_id
        })
    end
  end

  # POST /api/v1/drafts/:id/publish
  def publish_draft(conn, %{"id" => draft_id}) do
    draft = ContentForge.ContentGeneration.get_draft(draft_id)

    case draft do
      nil ->
        {:error, :not_found}

      %{status: "approved"} ->
        # Schedule immediate publishing
        Oban.insert(%{
          "draft_id" => draft_id
        })

        json(conn, %{
          status: "scheduled",
          draft_id: draft_id
        })

      _ ->
        {:error, :bad_request, "Draft must be approved before publishing"}
    end
  end

  # POST /api/v1/drafts/:id/publish-now
  def publish_now(conn, %{"id" => draft_id}) do
    draft = ContentForge.ContentGeneration.get_draft(draft_id)

    case draft do
      nil ->
        {:error, :not_found}

      _ ->
        # Schedule immediate publishing (runs as soon as possible)
        Oban.insert(%{
          "draft_id" => draft_id
        })

        json(conn, %{status: "scheduled", draft_id: draft_id})
    end
  end

  defp get_platforms_from_request(conn) do
    case conn.body_params do
      %{"platforms" => platforms} when is_list(platforms) -> platforms
      %{"platform" => platform} when is_binary(platform) -> [platform]
      _ -> ["twitter", "linkedin", "reddit", "facebook", "instagram"]
    end
  end

  defp schedule_for_platform(product, platform) do
    publishing_targets = product.publishing_targets || %{}
    platform_config = Map.get(publishing_targets, platform)

    if platform_config && platform_config["enabled"] do
      # Get optimal windows and schedule
      optimal_windows = Publishing.get_optimal_posting_windows(product.id, platform)
      now = DateTime.utc_now()

      {next_hour, next_day} = find_next_window(optimal_windows, now.hour, Date.day_of_week(now))
      delay = calculate_delay(next_hour, next_day, now)

      %{"product_id" => product.id, "platform" => platform}
      |> Publisher.new(scheduled_at: DateTime.add(now, delay, :second))
      |> Oban.insert()

      %{platform: platform, status: "scheduled", scheduled_in_seconds: delay}
    else
      %{platform: platform, status: "disabled"}
    end
  end

  defp find_next_window(windows, current_hour, current_day) do
    sorted = Enum.sort_by(windows, fn w -> {w.day, w.hour} end)

    case Enum.find(sorted, fn w ->
           w.day > current_day || (w.day == current_day && w.hour > current_hour)
         end) do
      nil ->
        first = List.first(sorted)
        {first.hour, first.day}

      window ->
        {window.hour, window.day}
    end
  end

  defp calculate_delay(target_hour, target_day, now) do
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
