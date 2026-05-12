defmodule ContentForge.Repo.Migrations.AddPublishedPlatformsToVideoJobs do
  use Ecto.Migration

  def change do
    # NOT NULL + default `[]` so pre-existing rows do not return
    # NULL through `published_to?/2`. The Ecto schema default of
    # `[]` only applies on insert through the changeset, which
    # leaves pre-migration rows with NULL otherwise.
    alter table(:video_jobs) do
      add :published_platforms, {:array, :string}, null: false, default: []
    end
  end
end
