defmodule ContentForge.Repo.Migrations.AddMediaForgeJobIdToDraftsAndVideoJobs do
  use Ecto.Migration

  def change do
    alter table(:drafts) do
      add :media_forge_job_id, :string
      add :error, :string
    end

    alter table(:video_jobs) do
      add :media_forge_job_id, :string
    end

    create index(:drafts, [:media_forge_job_id])
    create index(:video_jobs, [:media_forge_job_id])
  end
end
