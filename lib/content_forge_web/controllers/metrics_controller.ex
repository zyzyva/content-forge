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

    with nil <- product do
      {:error, :not_found}
    else
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

    with nil <- product do
      {:error, :not_found}
    else
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

    with nil <- product do
      {:error, :not_found}
    else
      _ ->
        # Aggregate metrics for the product
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

    with nil <- product do
      {:error, :not_found}
    else
      _ ->
        hot_content = Metrics.get_hot_content(product_id, platform)
        render(conn, :hot, entries: hot_content, product: product)
    end
  end

  # GET /api/products/:product_id/needs-reply
  def needs_reply(conn, %{"product_id" => product_id}) do
    product = Products.get_product(product_id)
    platform = conn.params["platform"]

    with nil <- product do
      {:error, :not_found}
    else
      _ ->
        needs_reply = Metrics.get_needs_reply(product_id, platform)
        render(conn, :needs_reply, entries: needs_reply, product: product)
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
