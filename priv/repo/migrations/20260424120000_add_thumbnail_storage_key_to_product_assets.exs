defmodule ContentForge.Repo.Migrations.AddThumbnailStorageKeyToProductAssets do
  use Ecto.Migration

  def change do
    alter table(:product_assets) do
      add :thumbnail_storage_key, :string
    end
  end
end
