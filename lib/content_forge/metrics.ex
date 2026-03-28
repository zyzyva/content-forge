defmodule ContentForge.Metrics do
  @moduledoc """
  Context for performance metrics, scoreboard tracking, model calibration,
  and video clip flagging.
  """

  import Ecto.Query
  alias ContentForge.Repo

  alias ContentForge.Metrics.ScoreboardEntry
  alias ContentForge.Metrics.ModelCalibration
  alias ContentForge.Metrics.ClipFlag
  alias ContentForge.Publishing.PublishedPost

  require Logger

  # ============================================
  # Scoreboard Entry CRUD
  # ============================================

  def list_scoreboard_entries(opts \\ []) do
    opts = Keyword.validate!(opts, [:product_id, :platform, :outcome, :limit])

    ScoreboardEntry
    |> maybe_filter_by_product(Keyword.get(opts, :product_id))
    |> maybe_filter_by_platform(Keyword.get(opts, :platform))
    |> maybe_filter_by_outcome(Keyword.get(opts, :outcome))
    |> maybe_limit(Keyword.get(opts, :limit, 100))
    |> order_by(desc: :measured_at)
    |> Repo.all()
  end

  def get_scoreboard_entry(id), do: Repo.get(ScoreboardEntry, id)

  def get_scoreboard_for_draft(draft_id) do
    ScoreboardEntry
    |> where(draft_id: ^draft_id)
    |> Repo.one()
  end

  def create_scoreboard_entry(attrs) do
    %ScoreboardEntry{}
    |> ScoreboardEntry.changeset(attrs)
    |> Repo.insert()
  end

  def update_scoreboard_entry(%ScoreboardEntry{} = entry, attrs) do
    entry
    |> ScoreboardEntry.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Get scoreboard entries needing measurement (pending outcome).
  """
  def get_pending_measurements(product_id, hours_old \\ 24) do
    cutoff = DateTime.utc_now() |> DateTime.add(-hours_old * 3600, :second)

    ScoreboardEntry
    |> where(product_id: ^product_id)
    |> where([e], is_nil(e.actual_engagement_score))
    |> where([e], e.measured_at <= ^cutoff)
    |> Repo.all()
  end

  # ============================================
  # Model Calibration CRUD
  # ============================================

  def list_model_calibration(opts \\ []) do
    opts = Keyword.validate!(opts, [:product_id, :model_name, :platform, :limit])

    ModelCalibration
    |> maybe_filter_by_product(Keyword.get(opts, :product_id))
    |> maybe_filter_by_model(Keyword.get(opts, :model_name))
    |> maybe_filter_by_platform(Keyword.get(opts, :platform))
    |> maybe_limit(Keyword.get(opts, :limit, 100))
    |> order_by(desc: :last_updated)
    |> Repo.all()
  end

  def get_model_calibration(product_id, model_name, platform, angle \\ nil) do
    ModelCalibration
    |> where(product_id: ^product_id)
    |> where(model_name: ^model_name)
    |> where(platform: ^platform)
    |> maybe_filter_by_angle(angle)
    |> Repo.one()
  end

  def upsert_model_calibration(attrs) do
    %ModelCalibration{}
    |> ModelCalibration.changeset(attrs)
    |> Repo.insert(
      on_conflict: [
        set: [
          avg_score_delta: attrs.avg_score_delta,
          sample_count: attrs.sample_count,
          last_updated: DateTime.utc_now()
        ]
      ],
      conflict_target: [:model_name, :product_id, :platform, :angle]
    )
  end

  @doc """
  Get calibration data for all models for a product.
  """
  def get_calibration_summary(product_id) do
    ModelCalibration
    |> where(product_id: ^product_id)
    |> group_by([:model_name])
    |> select([m], {m.model_name, sum(m.sample_count), avg(m.avg_score_delta)})
    |> Repo.all()
  end

  # ============================================
  # Clip Flag CRUD
  # ============================================

  def list_clip_flags(opts \\ []) do
    opts = Keyword.validate!(opts, [:video_id, :platform, :limit])

    ClipFlag
    |> maybe_filter_by_video(Keyword.get(opts, :video_id))
    |> maybe_filter_by_platform(Keyword.get(opts, :platform))
    |> maybe_limit(Keyword.get(opts, :limit, 50))
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def get_clip_flag(id), do: Repo.get(ClipFlag, id)

  def get_clip_flags_for_video(video_platform_id) do
    ClipFlag
    |> where(video_platform_id: ^video_platform_id)
    |> order_by(asc: :start_seconds)
    |> Repo.all()
  end

  def create_clip_flag(attrs) do
    %ClipFlag{}
    |> ClipFlag.changeset(attrs)
    |> Repo.insert()
  end

  def create_clip_flags(attrs_list) when is_list(attrs_list) do
    Repo.insert_all(ClipFlag, attrs_list, returning: true)
  end

  # ============================================
  # Analytics & Aggregation
  # ============================================

  @doc """
  Get the rolling average engagement score for a product/platform/angle combination.
  """
  def get_rolling_avg_engagement(product_id, platform, angle \\ nil, days \\ 30) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 24 * 3600, :second)

    query =
      ScoreboardEntry
      |> where(product_id: ^product_id)
      |> where(platform: ^platform)
      |> where([e], not is_nil(e.actual_engagement_score))
      |> where([e], e.measured_at >= ^cutoff)

    query =
      if angle do
        from e in query, where: e.angle == ^angle
      else
        query
      end

    result =
      query
      |> select([e], avg(e.actual_engagement_score))
      |> Repo.one()

    result || 0.0
  end

  @doc """
  Get hot content - entries with engagement significantly above rolling average.
  """
  def get_hot_content(product_id, platform \\ nil, _threshold \\ 2.0) do
    query =
      ScoreboardEntry
      |> where(product_id: ^product_id)
      |> where([e], not is_nil(e.actual_engagement_score))
      |> where([e], e.outcome == "winner")
      |> order_by(desc: :delta)

    query =
      if platform do
        from e in query, where: e.platform == ^platform
      else
        query
      end

    query
    |> limit(20)
    |> Repo.all()
  end

  @doc """
  Get content that needs a reply (high engagement but no follow-up).
  """
  def get_needs_reply(product_id, platform \\ nil, min_engagement \\ 50) do
    # Find published posts with high engagement that are winners
    query =
      from e in ScoreboardEntry,
        join: p in PublishedPost,
        on: p.draft_id == e.draft_id,
        where: e.product_id == ^product_id,
        where: e.outcome == "winner",
        where: e.actual_engagement_score >= ^min_engagement,
        order_by: [desc: e.actual_engagement_score],
        limit: 20

    query =
      if platform do
        from [e, p] in query, where: e.platform == ^platform
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Update scoreboard with actual engagement data and determine outcome.
  """
  def measure_and_update_scoreboard(%ScoreboardEntry{} = entry, actual_engagement) do
    # Get rolling average for comparison
    rolling_avg =
      get_rolling_avg_engagement(
        entry.product_id,
        entry.platform,
        entry.angle
      )

    # Normalize actual score
    normalized_actual = normalize_engagement(actual_engagement)

    # Calculate delta
    delta = normalized_actual - (entry.composite_ai_score || 0)

    # Determine outcome based on delta vs rolling average
    outcome =
      cond do
        normalized_actual > rolling_avg * 1.2 -> "winner"
        normalized_actual < rolling_avg * 0.8 -> "loser"
        true -> "pending"
      end

    entry
    |> ScoreboardEntry.changeset(%{
      actual_engagement_score: actual_engagement,
      delta: delta,
      outcome: outcome,
      measured_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  # ============================================
  # Model Calibration Update
  # ============================================

  @doc """
  Update model calibration based on a scoreboard entry.
  """
  def update_model_calibration(%ScoreboardEntry{} = entry, per_model_scores)
      when is_map(per_model_scores) do
    Enum.each(per_model_scores, fn {model_name, model_score} ->
      delta = (model_score || 0) - (entry.composite_ai_score || 0)

      case get_model_calibration(entry.product_id, model_name, entry.platform, entry.angle) do
        nil ->
          # Create new calibration
          upsert_model_calibration(%{
            model_name: model_name,
            product_id: entry.product_id,
            platform: entry.platform,
            angle: entry.angle,
            avg_score_delta: delta,
            sample_count: 1,
            last_updated: DateTime.utc_now()
          })

        calibration ->
          # Update existing
          calibration
          |> ModelCalibration.add_sample(delta)
          |> Repo.update!()
      end
    end)

    :ok
  end

  # ============================================
  # Brief Rewrite Trigger
  # ============================================

  @doc """
  Check if we need to trigger a brief rewrite based on poor performance.
  Returns true if 5+ new measured pieces have negative delta.
  """
  def should_trigger_rewrite?(product_id, platform, days \\ 7) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 24 * 3600, :second)

    negative_count =
      ScoreboardEntry
      |> where(product_id: ^product_id)
      |> where(platform: ^platform)
      |> where([e], not is_nil(e.actual_engagement_score))
      |> where([e], e.measured_at >= ^cutoff)
      |> where([e], e.delta < -1.0)
      |> select([e], count(e.id))
      |> Repo.one()

    negative_count >= 5
  end

  # ============================================
  # Helpers
  # ============================================

  defp maybe_filter_by_product(query, nil), do: query
  defp maybe_filter_by_product(query, product_id), do: where(query, product_id: ^product_id)

  defp maybe_filter_by_platform(query, nil), do: query
  defp maybe_filter_by_platform(query, platform), do: where(query, platform: ^platform)

  defp maybe_filter_by_outcome(query, nil), do: query
  defp maybe_filter_by_outcome(query, outcome), do: where(query, outcome: ^outcome)

  defp maybe_filter_by_model(query, nil), do: query
  defp maybe_filter_by_model(query, model_name), do: where(query, model_name: ^model_name)

  defp maybe_filter_by_angle(query, nil), do: query
  defp maybe_filter_by_angle(query, angle), do: where(query, angle: ^angle)

  defp maybe_filter_by_video(query, nil), do: query
  defp maybe_filter_by_video(query, video_id), do: where(query, video_id: ^video_id)

  defp maybe_limit(query, limit), do: limit(query, ^limit)

  defp normalize_engagement(score) when score <= 0, do: 0.0

  defp normalize_engagement(score) do
    raw = :math.log10(score + 1) * 3
    min(max(raw, 0), 10)
  end
end
