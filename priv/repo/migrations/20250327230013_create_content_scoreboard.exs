defmodule ContentForge.Repo.Migrations.CreateContentScoreboard do
  use Ecto.Migration

  def change do
    create table(:content_scoreboard, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :content_id, :binary_id, null: false

      add :product_id, references(:products, type: :binary_id, on_delete: :delete_all),
        null: false

      add :platform, :string, null: false
      add :angle, :string
      add :format, :string
      add :composite_ai_score, :float
      add :actual_engagement_score, :float
      add :delta, :float
      add :per_model_scores, :map
      add :outcome, :string
      add :measured_at, :utc_datetime

      add :draft_id, references(:drafts, type: :binary_id, on_delete: :delete_all)

      timestamps type: :utc_datetime
    end

    create index(:content_scoreboard, [:product_id])
    create index(:content_scoreboard, [:platform])
    create index(:content_scoreboard, [:outcome])
    create index(:content_scoreboard, [:measured_at])
    create index(:content_scoreboard, [:draft_id])
    create index(:content_scoreboard, [:product_id, :platform, :angle])
  end
end
