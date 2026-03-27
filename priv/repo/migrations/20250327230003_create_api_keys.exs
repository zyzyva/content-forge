defmodule ContentForge.Repo.Migrations.CreateApiKeys do
  use Ecto.Migration

  def change do
    create table(:api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :key, :string, null: false
      add :label, :string, null: false
      add :active, :boolean, default: true, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:api_keys, [:key], unique: true)
    create index(:api_keys, [:active])
  end
end
