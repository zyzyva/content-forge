defmodule ContentForge.Repo.Migrations.CreateDraftAssets do
  use Ecto.Migration

  def change do
    create table(:draft_assets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :draft_id,
          references(:drafts, type: :binary_id, on_delete: :delete_all),
          null: false

      add :asset_id,
          references(:product_assets, type: :binary_id, on_delete: :delete_all),
          null: false

      add :role, :string, null: false, default: "featured"

      # Microsecond precision so `list_assets_for_draft/1` returns rows
      # in attach order even when multiple attaches happen within the
      # same second.
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:draft_assets, [:draft_id, :asset_id],
             name: :draft_assets_draft_id_asset_id_index
           )

    create index(:draft_assets, [:draft_id])
    create index(:draft_assets, [:asset_id])
  end
end
