defmodule ContentForge.Metrics.ScoreboardEntry do
  @moduledoc """
  Schema for tracking content performance vs AI predictions.
  Links actual engagement scores to AI-composite scores and tracks model calibration.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "content_scoreboard" do
    field :content_id, :binary_id
    field :platform, :string
    field :angle, :string
    field :format, :string
    field :composite_ai_score, :float
    field :actual_engagement_score, :float
    field :delta, :float
    field :per_model_scores, :map
    field :outcome, :string
    field :measured_at, :utc_datetime

    belongs_to :product, ContentForge.Products.Product
    belongs_to :draft, ContentForge.ContentGeneration.Draft

    timestamps type: :utc_datetime
  end

  def changeset(scoreboard_entry, attrs) do
    scoreboard_entry
    |> cast(attrs, [
      :content_id,
      :product_id,
      :platform,
      :angle,
      :format,
      :composite_ai_score,
      :actual_engagement_score,
      :delta,
      :per_model_scores,
      :outcome,
      :measured_at,
      :draft_id
    ])
    |> validate_required([:content_id, :product_id, :platform])
    |> validate_inclusion(:platform, ~w(twitter linkedin reddit facebook instagram blog youtube))
    |> validate_inclusion(:outcome, ~w(winner loser pending), allow_nil: true)
    |> validate_number(:composite_ai_score,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 10
    )
    |> validate_number(:actual_engagement_score, greater_than_or_equal_to: 0)
    |> validate_number(:delta, greater_than_or_equal_to: -10, less_than_or_equal_to: 10)
    |> calculate_delta()
    |> determine_outcome()
  end

  defp calculate_delta(changeset) do
    ai_score =
      get_change(changeset, :composite_ai_score) || get_field(changeset, :composite_ai_score)

    actual_score =
      get_change(changeset, :actual_engagement_score) ||
        get_field(changeset, :actual_engagement_score)

    if ai_score && actual_score do
      # Normalize actual score to 0-10 scale for comparison
      normalized_actual = normalize_engagement(actual_score)
      put_change(changeset, :delta, normalized_actual - ai_score)
    else
      changeset
    end
  end

  defp normalize_engagement(score) do
    # Normalize engagement to 0-10 scale using logarithmic scaling
    # This handles varying scales across platforms
    if score <= 0 do
      0
    else
      raw = :math.log10(score + 1) * 3
      min(max(raw, 0), 10)
    end
  end

  defp determine_outcome(changeset) do
    delta = get_change(changeset, :delta) || get_field(changeset, :delta)
    measured_at = get_field(changeset, :measured_at)

    if delta && measured_at do
      # Only mark as winner/loser if we have enough historical data
      outcome =
        cond do
          delta > 2 -> "winner"
          delta < -2 -> "loser"
          true -> "pending"
        end

      put_change(changeset, :outcome, outcome)
    else
      changeset
    end
  end

  # For creating entries directly from drafts with AI scores
  def from_draft(
        %ContentForge.ContentGeneration.Draft{} = draft,
        ai_composite_score,
        model_scores
      ) do
    %__MODULE__{}
    |> changeset(%{
      content_id: draft.id,
      product_id: draft.product_id,
      platform: draft.platform,
      angle: draft.angle,
      format: draft.content_type,
      composite_ai_score: ai_composite_score,
      per_model_scores: model_scores,
      measured_at: DateTime.utc_now(),
      draft_id: draft.id
    })
  end
end
