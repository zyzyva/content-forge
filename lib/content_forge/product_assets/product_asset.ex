defmodule ContentForge.ProductAssets.ProductAsset do
  @moduledoc """
  A product-level asset (image or video) registered in Content Forge.

  The row tracks the R2/Bunny object key under which the original bytes
  live (written by the presigned-upload flow in a later slice), the
  uploader-facing metadata (filename, mime, size), and the processing
  state (`pending`, `processed`, `failed`, `deleted`). Dimensions and
  duration are filled in once Media Forge has probed the original.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @media_types ~w(image video)
  @statuses ~w(pending processed failed deleted)

  schema "product_assets" do
    field :storage_key, :string
    field :media_type, :string
    field :filename, :string
    field :mime_type, :string
    field :byte_size, :integer
    field :duration_ms, :integer
    field :width, :integer
    field :height, :integer
    field :uploaded_at, :utc_datetime_usec
    field :uploader, :string
    field :tags, {:array, :string}, default: []
    field :description, :string
    field :status, :string, default: "pending"
    field :error, :string
    field :thumbnail_storage_key, :string
    field :normalized_storage_key, :string

    belongs_to :product, ContentForge.Products.Product

    timestamps(type: :utc_datetime)
  end

  @required ~w(product_id storage_key media_type filename mime_type byte_size uploaded_at)a
  @optional ~w(duration_ms width height uploader tags description status error thumbnail_storage_key normalized_storage_key)a

  @doc "Changeset used for `create_asset/1` and generic `update_asset/2`."
  def changeset(asset, attrs) do
    asset
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:media_type, @media_types)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:byte_size, greater_than: 0)
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0)
    |> validate_number(:width, greater_than: 0)
    |> validate_number(:height, greater_than: 0)
    |> foreign_key_constraint(:product_id)
    |> unique_constraint(
      [:product_id, :storage_key],
      name: :product_assets_product_id_storage_key_active_index,
      message: "already registered for this product"
    )
  end

  @doc """
  Changeset used by `mark_processed/2`: moves status from `pending` to
  `processed` and writes the dimensions/duration Media Forge probed.
  """
  def mark_processed_changeset(asset, attrs) do
    asset
    |> cast(attrs, [
      :width,
      :height,
      :duration_ms,
      :thumbnail_storage_key,
      :normalized_storage_key
    ])
    |> put_change(:status, "processed")
    |> put_change(:error, nil)
    |> validate_number(:width, greater_than: 0)
    |> validate_number(:height, greater_than: 0)
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0)
  end

  @doc """
  Changeset used by `mark_failed/2`: flips status to `failed` and stores
  the error string for dashboard display.
  """
  def mark_failed_changeset(asset, reason) when is_binary(reason) do
    change(asset, %{status: "failed", error: reason})
  end

  @doc "Changeset used by `soft_delete_asset/1`."
  def soft_delete_changeset(asset) do
    change(asset, %{status: "deleted"})
  end
end
