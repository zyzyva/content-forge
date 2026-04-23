defmodule ContentForgeWeb.MetricsJSONTest do
  @moduledoc """
  Smoke tests for the `MetricsJSON` view shape. Added during the
  15.3a coverage-uplift triage to bring the module above 0%. The
  underlying endpoints (MetricsController) are in the defer bucket
  and will get full coverage in a later slice.
  """
  use ExUnit.Case, async: true

  alias ContentForge.Metrics.ClipFlag
  alias ContentForge.Metrics.ModelCalibration
  alias ContentForge.Metrics.ScoreboardEntry
  alias ContentForge.Products.Product
  alias ContentForgeWeb.MetricsJSON

  test "scoreboard/1 renders product + entries + total_count" do
    product = %Product{id: "pid-1", name: "Product"}

    entry = %ScoreboardEntry{
      id: "e1",
      content_id: "c1",
      platform: "twitter",
      angle: "educational",
      format: "text",
      composite_ai_score: 8.5,
      actual_engagement_score: 9.0,
      delta: 0.5,
      per_model_scores: %{"claude" => 8.7},
      outcome: "winner",
      measured_at: ~U[2026-01-01 00:00:00Z],
      draft_id: "d1",
      inserted_at: ~U[2026-01-01 00:00:00Z],
      updated_at: ~U[2026-01-01 00:00:00Z]
    }

    assert %{
             data: %{
               product_id: "pid-1",
               product_name: "Product",
               entries: [%{id: "e1", outcome: "winner"}],
               total_count: 1
             }
           } = MetricsJSON.scoreboard(%{entries: [entry], product: product})
  end

  test "calibration/1 renders product + calibrations list" do
    product = %Product{id: "pid-2", name: "Product 2"}

    calibration = %ModelCalibration{
      id: "cal-1",
      model_name: "claude",
      platform: "twitter",
      angle: "humor",
      avg_score_delta: 0.25,
      sample_count: 42,
      last_updated: ~U[2026-01-01 00:00:00Z]
    }

    assert %{data: %{product_id: "pid-2", calibrations: [%{model_name: "claude"}]}} =
             MetricsJSON.calibration(%{calibrations: [calibration], product: product})
  end

  test "retention/1 renders serialized clip flags + retention curve" do
    flag = %ClipFlag{
      id: "flag-1",
      video_id: "vid-1",
      video_platform_id: "yt-abc",
      platform: "youtube",
      start_seconds: 10,
      end_seconds: 40,
      suggested_title: "Key moment",
      engagement_spike_data: %{"spike_type" => "plateau"},
      inserted_at: ~U[2026-01-01 00:00:00Z]
    }

    assert %{
             data: %{
               video_id: "yt-abc",
               clip_flags: [%{id: "flag-1", spike_type: "plateau"}],
               total_clips: 1
             }
           } =
             MetricsJSON.retention(%{
               video_id: "yt-abc",
               clip_flags: [flag],
               retention_data: %{"data" => []}
             })
  end
end
