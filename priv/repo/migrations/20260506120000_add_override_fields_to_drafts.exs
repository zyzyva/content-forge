defmodule ContentForge.Repo.Migrations.AddOverrideFieldsToDrafts do
  use Ecto.Migration

  def change do
    alter table(:drafts) do
      add :approved_via_override, :boolean, default: false, null: false
      add :override_reason, :text
      add :override_score_at_approval, :integer
      add :override_research_status_at_approval, :string
    end
  end
end
