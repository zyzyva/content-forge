defmodule ContentForge.ContentGeneration.DraftScore do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "draft_scores" do
    field :model_name, :string
    field :accuracy_score, :float
    field :seo_score, :float
    field :eev_score, :float
    field :composite_score, :float
    field :critique, :string

    belongs_to :draft, ContentForge.ContentGeneration.Draft

    timestamps type: :utc_datetime
  end

  def changeset(draft_score, attrs) do
    draft_score
    |> cast(attrs, [
      :draft_id,
      :model_name,
      :accuracy_score,
      :seo_score,
      :eev_score,
      :composite_score,
      :critique
    ])
    |> validate_required([:draft_id, :model_name])
    |> validate_inclusion(:model_name, ~w(claude gemini xai))
    |> validate_number(:accuracy_score, greater_than_or_equal_to: 0, less_than_or_equal_to: 10)
    |> validate_number(:seo_score, greater_than_or_equal_to: 0, less_than_or_equal_to: 10)
    |> validate_number(:eev_score, greater_than_or_equal_to: 0, less_than_or_equal_to: 10)
    |> validate_number(:composite_score, greater_than_or_equal_to: 0, less_than_or_equal_to: 10)
    |> unique_constraint([:draft_id, :model_name])
  end
end