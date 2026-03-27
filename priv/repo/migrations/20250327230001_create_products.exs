defmodule ContentForge.Repo.Migrations.CreateProducts do
  use Ecto.Migration

  def change do
    create table(:products, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :repo_url, :string
      add :site_url, :string
      add :voice_profile, :text, null: false
      add :publishing_targets, :map

      timestamps(type: :utc_datetime)
    end
  end
end
