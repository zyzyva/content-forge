defmodule ContentForge.Repo.Migrations.CreateProductAssets do
  use Ecto.Migration

  def change do
    create table(:product_assets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :product_id,
          references(:products, type: :binary_id, on_delete: :nilify_all),
          null: true

      add :storage_key, :string, null: false
      add :media_type, :string, null: false
      add :filename, :string, null: false
      add :mime_type, :string, null: false
      add :byte_size, :bigint, null: false
      add :duration_ms, :integer
      add :width, :integer
      add :height, :integer
      add :uploaded_at, :utc_datetime_usec, null: false
      add :uploader, :string
      add :tags, {:array, :string}, null: false, default: []
      add :description, :text
      add :status, :string, null: false, default: "pending"
      add :error, :text

      timestamps(type: :utc_datetime)
    end

    create index(:product_assets, [:product_id, :status])
    create index(:product_assets, [:tags], using: :gin)

    # Partial unique: the same storage_key cannot appear twice for the same
    # product while the asset is still active. Soft-deleted rows are
    # excluded so future re-registration of the same object key is allowed
    # if needed.
    create unique_index(
             :product_assets,
             [:product_id, :storage_key],
             where: "status <> 'deleted'",
             name: :product_assets_product_id_storage_key_active_index
           )
  end
end
