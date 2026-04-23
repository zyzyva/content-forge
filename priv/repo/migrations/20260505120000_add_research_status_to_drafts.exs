defmodule ContentForge.Repo.Migrations.AddResearchStatusToDrafts do
  use Ecto.Migration

  def change do
    alter table(:drafts) do
      add :research_status, :string, default: "none", null: false
      add :research_source, :string
    end
  end
end
