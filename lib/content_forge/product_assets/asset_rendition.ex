defmodule ContentForge.ProductAssets.AssetRendition do
  @moduledoc """
  Cached platform-specific rendition of a `ProductAsset` produced by
  Media Forge.

  Each row is keyed by `(asset_id, platform)`; the `storage_key`
  captures the R2 object Media Forge wrote its output to. The
  `RenditionResolver` uses this cache to avoid re-rendering the same
  (asset, platform) pair on every publish.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(ready pending failed)

  schema "asset_renditions" do
    field :platform, :string
    field :storage_key, :string
    field :media_forge_job_id, :string
    field :status, :string, default: "ready"
    field :width, :integer
    field :height, :integer
    field :format, :string
    field :generated_at, :utc_datetime

    belongs_to :asset, ContentForge.ProductAssets.ProductAsset

    timestamps(type: :utc_datetime)
  end

  @required ~w(asset_id platform storage_key)a
  @optional ~w(media_forge_job_id status width height format generated_at)a

  def changeset(row, attrs) do
    row
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:asset_id, :platform],
      name: :asset_renditions_asset_id_platform_index,
      message: "rendition already exists for this (asset, platform)"
    )
    |> foreign_key_constraint(:asset_id)
  end
end
