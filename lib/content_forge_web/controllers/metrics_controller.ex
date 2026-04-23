defmodule ContentForgeWeb.MetricsController do
  @moduledoc """
  API controller for metrics, scoreboard, and clip flag endpoints.
  """

  use ContentForgeWeb, :controller

  import Ecto.Query

  alias ContentForge.Metrics
  alias ContentForge.Products
  alias ContentForge.Publishing.PublishedPost
  alias ContentForge.Repo

  action_fallback ContentForgeWeb.FallbackController

  # GET /api/products/:product_id/scoreboard
  def scoreboard(conn, %{"product_id" => product_id}) do
    product = Products.get_product(product_id)

    case product do
      nil ->
        {:error, :not_found}

      _ ->
        entries =
          Metrics.list_scoreboard_entries(
            product_id: product_id,
            limit: 100
          )

        render(conn, :scoreboard, entries: entries, product: product)
    end
  end

  # GET /api/products/:product_id/calibration
  def calibration(conn, %{"product_id" => product_id}) do
    product = Products.get_product(product_id)

    case product do
      nil ->
        {:error, :not_found}

      _ ->
        calibrations =
          Metrics.list_model_calibration(
            product_id: product_id,
            limit: 100
          )

        render(conn, :calibration, calibrations: calibrations, product: product)
    end
  end

  # GET /api/products/:product_id/metrics
  def metrics(conn, %{"product_id" => product_id}) do
    product = Products.get_product(product_id)

    case product do
      nil ->
        {:error, :not_found}

      _ ->
        platforms = ~w(twitter linkedin reddit facebook instagram blog youtube)

        platform_metrics =
          Enum.reduce(platforms, %{}, fn platform, acc ->
            avg_engagement = Metrics.get_rolling_avg_engagement(product_id, platform)
            hot_count = length(Metrics.get_hot_content(product_id, platform))

            Map.put(acc, platform, %{
              rolling_avg_engagement: avg_engagement,
              hot_content_count: hot_count
            })
          end)

        render(conn, :metrics,
          product: product,
          platform_metrics: platform_metrics,
          calibration_summary: Metrics.get_calibration_summary(product_id)
        )
    end
  end

  # GET /api/products/:product_id/hot
  def hot(conn, %{"product_id" => product_id}) do
    product = Products.get_product(product_id)
    platform = conn.params["platform"]

    case product do
      nil ->
        {:error, :not_found}

      _ ->
        hot_content = Metrics.get_hot_content(product_id, platform)
        render(conn, :hot, entries: hot_content, product: product)
    end
  end

  # GET /api/products/:product_id/needs-reply
  def needs_reply(conn, %{"product_id" => product_id}) do
    product = Products.get_product(product_id)
    platform = conn.params["platform"]

    case product do
      nil ->
        {:error, :not_found}

      _ ->
        needs_reply = Metrics.get_needs_reply(product_id, platform)
        render(conn, :needs_reply, entries: needs_reply, product: product)
    end
  end

  # POST /api/videos/:video_id/clip
  def clip(conn, %{"video_id" => video_id, "flag_id" => flag_id}) do
    flag = Metrics.get_clip_flag(flag_id)

    cond do
      is_nil(flag) ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Clip flag not found"})

      flag.video_platform_id != video_id and to_string(flag.video_id) != video_id ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Flag does not belong to this video"})

      true ->
        {:ok, updated_flag} = Metrics.approve_clip_flag(flag)

        json(conn, %{
          message: "Segment approved for clip production",
          clip: %{
            id: updated_flag.id,
            video_id: video_id,
            start_seconds: updated_flag.start_seconds,
            end_seconds: updated_flag.end_seconds,
            suggested_title: updated_flag.suggested_title,
            status: "approved"
          }
        })
    end
  end

  def clip(conn, %{"video_id" => video_id}) do
    flags = Metrics.get_clip_flags_for_video(video_id)

    best_flag =
      Enum.max_by(flags, fn f -> f.segment_engagement_rate || 0 end, &>=/2, fn -> nil end)

    cond do
      flags == [] ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "No clip flags found for this video"})

      is_nil(best_flag) or is_nil(best_flag.segment_engagement_rate) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "No suitable clip flags found with engagement data"})

      true ->
        {:ok, updated_flag} = Metrics.approve_clip_flag(best_flag)

        json(conn, %{
          message: "Best segment approved for clip production",
          clip: %{
            id: updated_flag.id,
            video_id: video_id,
            start_seconds: updated_flag.start_seconds,
            end_seconds: updated_flag.end_seconds,
            suggested_title: updated_flag.suggested_title,
            engagement_rate: updated_flag.segment_engagement_rate,
            status: "approved"
          }
        })
    end
  end

  # GET /api/videos/:video_id/retention
  def video_retention(conn, %{"video_id" => video_id}) do
    # Look up by platform video ID
    clip_flags = Metrics.get_clip_flags_for_video(video_id)

    # Get published post for retention data
    post =
      PublishedPost
      |> where(platform_post_id: ^video_id)
      |> where(platform: "youtube")
      |> Repo.one()

    retention_data =
      if post do
        post.engagement_data
      else
        nil
      end

    render(conn, :retention,
      video_id: video_id,
      clip_flags: clip_flags,
      retention_data: retention_data
    )
  end
end
