defmodule ContentForge.Repo.Migrations.AddPublishedPlatformsToVideoJobs do
  use Ecto.Migration

  def change do
    alter table(:video_jobs) do
      add :published_platforms, {:array, :string}
    end
  end
end