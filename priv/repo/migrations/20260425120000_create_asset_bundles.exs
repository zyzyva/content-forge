defmodule ContentForge.Repo.Migrations.CreateAssetBundles do
  use Ecto.Migration

  def change do
    create table(:asset_bundles, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :product_id,
          references(:products, type: :binary_id, on_delete: :delete_all),
          null: false

      add :name, :string, null: false
      add :context, :text
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime)
    end

    create index(:asset_bundles, [:product_id, :status])

    create table(:bundle_assets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :bundle_id,
          references(:asset_bundles, type: :binary_id, on_delete: :delete_all),
          null: false

      add :asset_id,
          references(:product_assets, type: :binary_id, on_delete: :delete_all),
          null: false

      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:bundle_assets, [:bundle_id])
    create unique_index(:bundle_assets, [:bundle_id, :asset_id])
  end
end
