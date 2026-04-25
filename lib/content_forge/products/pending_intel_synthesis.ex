defmodule ContentForge.Products.PendingIntelSynthesis do
  @moduledoc """
  Phase 17.4 without-key route. Each row marks a competitor
  intel synthesis attempt the autonomous synthesizer could not
  complete (no `ANTHROPIC_API_KEY` configured) and that a
  Claude Code session must finish by hand via the MCP surface.

  Rows are resolved (deleted) by `cf_store_intel` when a
  manual synthesis lands for the matching `(product_id,
  window)` pair, so the queue stays bounded.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @windows ~w(all week month)

  schema "pending_intel_syntheses" do
    field :window, :string
    field :source_post_ids, {:array, :binary_id}, default: []
    field :note, :string

    belongs_to :product, ContentForge.Products.Product

    timestamps(type: :utc_datetime)
  end

  @required ~w(product_id)a
  @optional ~w(window source_post_ids note)a

  def changeset(row, attrs) do
    row
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:window, @windows, allow_nil: true)
    |> foreign_key_constraint(:product_id)
  end
end
