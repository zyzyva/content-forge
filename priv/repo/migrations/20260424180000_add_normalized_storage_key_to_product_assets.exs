defmodule ContentForge.Repo.Migrations.AddNormalizedStorageKeyToProductAssets do
  use Ecto.Migration

  def change do
    alter table(:product_assets) do
      add :normalized_storage_key, :string
    end
  end
end
