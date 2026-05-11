defmodule ContentForge.Products.CompetitorIntel do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "competitor_intel" do
    field :summary, :string
    field :source_count, :integer
    field :trending_topics, {:array, :string}
    field :winning_formats, {:array, :string}
    field :effective_hooks, {:array, :string}
    field :audience_signals, {:array, :string}, default: []
    field :window, :string

    belongs_to :product, ContentForge.Products.Product

    timestamps type: :utc_datetime
  end

  @windows ~w(all week month)

  def changeset(intel, attrs) do
    intel
    |> cast(attrs, [
      :product_id,
      :summary,
      :source_count,
      :trending_topics,
      :winning_formats,
      :effective_hooks,
      :audience_signals,
      :window
    ])
    |> validate_required([:product_id, :summary])
    |> validate_inclusion(:window, @windows, allow_nil: true)
  end
end
