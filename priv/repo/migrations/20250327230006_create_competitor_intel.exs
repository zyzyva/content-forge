defmodule ContentForge.Repo.Migrations.CreateCompetitorIntel do
  use Ecto.Migration

  def change do
    create table(:competitor_intel, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :product_id, references(:products, type: :binary_id, on_delete: :delete_all),
        null: false

      add :summary, :text, null: false
      add :source_count, :integer, default: 0
      add :trending_topics, :jsonb
      add :winning_formats, :jsonb
      add :effective_hooks, :jsonb

      timestamps type: :utc_datetime
    end

    create index(:competitor_intel, [:product_id])
  end
end
