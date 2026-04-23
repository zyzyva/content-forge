defmodule ContentForge.ContentGeneration.DraftAsset do
  @moduledoc """
  Join row between a `ContentGeneration.Draft` and a
  `ProductAssets.ProductAsset`. `role` distinguishes a single
  `"featured"` asset (the one that would be used as the post image when
  `draft.image_url` is swapped to this relation in Phase 13.5) from
  `"gallery"` assets (supporting media bundled with the draft).

  Composite uniqueness on `(draft_id, asset_id)` guarantees each asset
  appears at most once per draft.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @roles ~w(featured gallery)

  schema "draft_assets" do
    field :role, :string, default: "featured"

    belongs_to :draft, ContentForge.ContentGeneration.Draft
    belongs_to :asset, ContentForge.ProductAssets.ProductAsset

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [:draft_id, :asset_id, :role])
    |> validate_required([:draft_id, :asset_id])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:draft_id, :asset_id],
      name: :draft_assets_draft_id_asset_id_index,
      message: "asset already attached to draft"
    )
    |> foreign_key_constraint(:draft_id)
    |> foreign_key_constraint(:asset_id)
  end
end
