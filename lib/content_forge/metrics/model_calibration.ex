defmodule ContentForge.Metrics.ModelCalibration do
  @moduledoc """
  Schema for tracking how well each AI model predicts actual engagement.
  Helps identify which models are over/under-confident for different contexts.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "model_calibration" do
    field :model_name, :string
    field :platform, :string
    field :angle, :string
    field :avg_score_delta, :float
    field :sample_count, :integer
    field :last_updated, :utc_datetime

    belongs_to :product, ContentForge.Products.Product

    timestamps type: :utc_datetime
  end

  def changeset(model_calibration, attrs) do
    model_calibration
    |> cast(attrs, [
      :model_name,
      :product_id,
      :platform,
      :angle,
      :avg_score_delta,
      :sample_count,
      :last_updated
    ])
    |> validate_required([:model_name, :product_id, :platform])
    |> validate_inclusion(:model_name, ~w(claude gemini xai))
    |> validate_inclusion(:platform, ~w(twitter linkedin reddit facebook instagram blog youtube))
    |> validate_number(:avg_score_delta, greater_than_or_equal_to: -10, less_than_or_equal_to: 10)
    |> validate_number(:sample_count, greater_than_or_equal_to: 0)
    |> unique_constraint([:model_name, :product_id, :platform, :angle])
  end

  @doc """
  Creates a new calibration entry or updates existing one with new delta.
  """
  def add_sample(%__MODULE__{} = calibration, delta) do
    current_count = calibration.sample_count || 0
    current_avg = calibration.avg_score_delta || 0.0

    new_count = current_count + 1
    new_avg = (current_avg * current_count + delta) / new_count

    calibration
    |> changeset(%{
      avg_score_delta: new_avg,
      sample_count: new_count,
      last_updated: DateTime.utc_now()
    })
  end

  @doc """
  Check if a model tends to over-predict (positive delta) or under-predict (negative delta).
  """
  def prediction_bias(%__MODULE__{avg_score_delta: delta}) when delta > 0.5, do: :over_predicts
  def prediction_bias(%__MODULE__{avg_score_delta: delta}) when delta < -0.5, do: :under_predicts
  def prediction_bias(%__MODULE__{}), do: :calibrated
end
