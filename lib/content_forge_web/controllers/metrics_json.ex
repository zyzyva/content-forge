defmodule ContentForgeWeb.MetricsJSON do
  alias ContentForge.Metrics.ScoreboardEntry
  alias ContentForge.Metrics.ModelCalibration
  alias ContentForge.Metrics.ClipFlag
  alias ContentForge.Products.Product

  def scoreboard(%{entries: entries, product: %Product{} = product}) do
    %{
      data: %{
        product_id: product.id,
        product_name: product.name,
        entries: Enum.map(entries, &scoreboard_entry/1),
        total_count: length(entries)
      }
    }
  end

  def scoreboard_entry(%ScoreboardEntry{} = entry) do
    %{
      id: entry.id,
      content_id: entry.content_id,
      platform: entry.platform,
      angle: entry.angle,
      format: entry.format,
      composite_ai_score: entry.composite_ai_score,
      actual_engagement_score: entry.actual_engagement_score,
      delta: entry.delta,
      per_model_scores: entry.per_model_scores,
      outcome: entry.outcome,
      measured_at: entry.measured_at,
      draft_id: entry.draft_id,
      inserted_at: entry.inserted_at,
      updated_at: entry.updated_at
    }
  end

  def calibration(%{calibrations: calibrations, product: %Product{} = product}) do
    %{
      data: %{
        product_id: product.id,
        product_name: product.name,
        calibrations: Enum.map(calibrations, &model_calibration/1)
      }
    }
  end

  def model_calibration(%ModelCalibration{} = cal) do
    %{
      id: cal.id,
      model_name: cal.model_name,
      platform: cal.platform,
      angle: cal.angle,
      avg_score_delta: cal.avg_score_delta,
      sample_count: cal.sample_count,
      last_updated: cal.last_updated,
      prediction_bias: prediction_bias(cal),
      inserted_at: cal.inserted_at,
      updated_at: cal.updated_at
    }
  end

  defp prediction_bias(%ModelCalibration{avg_score_delta: delta}) when delta > 0.5,
    do: "over_predicts"

  defp prediction_bias(%ModelCalibration{avg_score_delta: delta}) when delta < -0.5,
    do: "under_predicts"

  defp prediction_bias(%ModelCalibration{}), do: "calibrated"

  def metrics(%{
        product: %Product{} = product,
        platform_metrics: platform_metrics,
        calibration_summary: summary
      }) do
    %{
      data: %{
        product_id: product.id,
        product_name: product.name,
        platforms: platform_metrics,
        model_calibration: format_calibration_summary(summary),
        generated_at: DateTime.utc_now()
      }
    }
  end

  defp format_calibration_summary([]), do: []

  defp format_calibration_summary(summary) do
    Enum.map(summary, fn {model, count, avg_delta} ->
      %{
        model_name: model,
        total_samples: count,
        avg_delta: avg_delta,
        prediction_bias:
          if(avg_delta > 0.5,
            do: "over_predicts",
            else: if(avg_delta < -0.5, do: "under_predicts", else: "calibrated")
          )
      }
    end)
  end

  def hot(%{entries: entries, product: %Product{} = product}) do
    %{
      data: %{
        product_id: product.id,
        product_name: product.name,
        hot_content: Enum.map(entries, &scoreboard_entry/1),
        count: length(entries)
      }
    }
  end

  def needs_reply(%{entries: entries, product: %Product{} = product}) do
    %{
      data: %{
        product_id: product.id,
        product_name: product.name,
        posts_needing_reply: Enum.map(entries, &scoreboard_entry/1),
        count: length(entries)
      }
    }
  end

  def retention(%{video_id: video_id, clip_flags: flags, retention_data: data}) do
    %{
      data: %{
        video_id: video_id,
        clip_flags: Enum.map(flags, &clip_flag/1),
        retention_curve: data,
        total_clips: length(flags)
      }
    }
  end

  def clip_flag(%ClipFlag{} = flag) do
    %{
      id: flag.id,
      video_id: flag.video_id,
      video_platform_id: flag.video_platform_id,
      platform: flag.platform,
      start_seconds: flag.start_seconds,
      end_seconds: flag.end_seconds,
      suggested_title: flag.suggested_title,
      segment_views: flag.segment_views,
      segment_engagement_rate: flag.segment_engagement_rate,
      spike_type: flag.engagement_spike_data && flag.engagement_spike_data["spike_type"],
      inserted_at: flag.inserted_at,
      updated_at: flag.updated_at
    }
  end
end
