defmodule ContentForge.ProductAssets.AssetBundle do
  @moduledoc """
  A named collection of product assets (for example "Johnson family
  kitchen remodel, 3 weeks, quartz counters, custom cabinets"). Bundles
  group assets for draft generation and publishing flows.

  Membership is tracked via `ContentForge.ProductAssets.BundleAsset`
  join rows that carry a `position` for display order within the bundle.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active archived deleted)

  schema "asset_bundles" do
    field :name, :string
    field :context, :string
    field :status, :string, default: "active"

    belongs_to :product, ContentForge.Products.Product

    has_many :bundle_assets, ContentForge.ProductAssets.BundleAsset,
      foreign_key: :bundle_id,
      on_delete: :delete_all,
      preload_order: [asc: :position]

    has_many :assets,
      through: [:bundle_assets, :asset]

    timestamps(type: :utc_datetime)
  end

  @required ~w(product_id name)a
  @optional ~w(context status)a

  def changeset(bundle, attrs) do
    bundle
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:name, min: 1, max: 120)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:product_id)
  end

  def archive_changeset(bundle), do: change(bundle, %{status: "archived"})

  def soft_delete_changeset(bundle), do: change(bundle, %{status: "deleted"})
end
