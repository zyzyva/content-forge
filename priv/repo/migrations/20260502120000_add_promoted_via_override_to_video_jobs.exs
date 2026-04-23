defmodule ContentForge.Repo.Migrations.AddPromotedViaOverrideToVideoJobs do
  use Ecto.Migration

  def change do
    alter table(:video_jobs) do
      add :promoted_via_override, :boolean, null: false, default: false
      add :promoted_score, :float
      add :promoted_threshold, :float
    end
  end
end
