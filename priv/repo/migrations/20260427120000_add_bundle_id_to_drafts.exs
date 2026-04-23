defmodule ContentForge.Repo.Migrations.AddBundleIdToDrafts do
  use Ecto.Migration

  def change do
    alter table(:drafts) do
      # Optional link back to the AssetBundle that generated this draft.
      # `on_delete: :nilify_all` so deleting the source bundle does not
      # destroy its generated drafts (draft history is load-bearing for
      # performance analysis).
      add :bundle_id,
          references(:asset_bundles, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:drafts, [:bundle_id])
  end
end
