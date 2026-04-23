defmodule ContentForge.ProductAssets.BundleAsset do
  @moduledoc """
  Join row between an `AssetBundle` and a `ProductAsset` with an integer
  `position` for display order within the bundle.

  Composite uniqueness on `(bundle_id, asset_id)` guarantees an asset
  appears in a given bundle at most once.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "bundle_assets" do
    field :position, :integer, default: 0

    belongs_to :bundle, ContentForge.ProductAssets.AssetBundle
    belongs_to :asset, ContentForge.ProductAssets.ProductAsset

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [:bundle_id, :asset_id, :position])
    |> validate_required([:bundle_id, :asset_id])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> unique_constraint([:bundle_id, :asset_id],
      name: :bundle_assets_bundle_id_asset_id_index,
      message: "asset already in bundle"
    )
    |> foreign_key_constraint(:bundle_id)
    |> foreign_key_constraint(:asset_id)
  end
end
