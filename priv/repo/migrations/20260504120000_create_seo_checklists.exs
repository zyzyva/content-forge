defmodule ContentForge.Repo.Migrations.CreateSeoChecklists do
  use Ecto.Migration

  def change do
    create table(:seo_checklists, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :draft_id, references(:drafts, type: :binary_id, on_delete: :delete_all), null: false
      add :results, :map, null: false, default: %{}
      add :score, :integer, null: false, default: 0
      add :run_at, :utc_datetime_usec, null: false

      timestamps type: :utc_datetime
    end

    create unique_index(:seo_checklists, [:draft_id])

    alter table(:drafts) do
      add :seo_score, :integer
    end
  end
end
