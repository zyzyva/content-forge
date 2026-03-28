defmodule ContentForge.Products.CompetitorAccount do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "competitor_accounts" do
    field :platform, :string
    field :handle, :string
    field :url, :string
    field :active, :boolean, default: true

    belongs_to :product, ContentForge.Products.Product

    timestamps type: :utc_datetime
  end

  def changeset(competitor, attrs) do
    competitor
    |> cast(attrs, [:product_id, :platform, :handle, :url, :active])
    |> validate_required([:product_id, :platform, :handle])
    |> validate_inclusion(:platform, [
      "twitter",
      "linkedin",
      "instagram",
      "youtube",
      "reddit",
      "facebook"
    ])
  end
end
