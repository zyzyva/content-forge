defmodule ContentForge.Repo.Migrations.CreateAssetRenditions do
  use Ecto.Migration

  def change do
    create table(:asset_renditions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :asset_id,
          references(:product_assets, type: :binary_id, on_delete: :delete_all),
          null: false

      add :platform, :string, null: false
      add :storage_key, :string, null: false
      add :media_forge_job_id, :string
      add :status, :string, null: false, default: "ready"
      add :width, :integer
      add :height, :integer
      add :format, :string
      add :generated_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # One cached rendition per (asset, platform). Retrying a failed
    # rendition updates this row in-place rather than creating a new one.
    create unique_index(:asset_renditions, [:asset_id, :platform],
             name: :asset_renditions_asset_id_platform_index
           )

    # Partial unique on storage_key while the row is ready - prevents two
    # distinct (asset, platform) caches from accidentally sharing the
    # same output key. Pending / failed rows may share `""` placeholders.
    create unique_index(:asset_renditions, [:storage_key],
             where: "status = 'ready'",
             name: :asset_renditions_storage_key_ready_index
           )

    create index(:asset_renditions, [:asset_id])
  end
end
