defmodule ContentForge.Products.ProductSnapshot do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "product_snapshots" do
    field :snapshot_type, :string
    field :r2_keys, :map
    field :token_count, :integer
    field :content_summary, :string

    belongs_to :product, ContentForge.Products.Product

    timestamps type: :utc_datetime
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:product_id, :snapshot_type, :r2_keys, :token_count, :content_summary])
    |> validate_required([:product_id, :snapshot_type, :r2_keys])
    |> validate_inclusion(:snapshot_type, ["repo", "site"])
  end
end
