defmodule ContentForge.Repo.Migrations.AddAiSummaryNuggetToDrafts do
  use Ecto.Migration

  def change do
    alter table(:drafts) do
      add :ai_summary_nugget, :text
    end
  end
end
