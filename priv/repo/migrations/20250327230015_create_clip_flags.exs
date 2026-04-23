defmodule ContentForge.Repo.Migrations.CreateClipFlag do
  use Ecto.Migration

  def change do
    create table(:clip_flags, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :video_id, :binary_id, null: false
      add :video_platform_id, :string, null: false
      add :platform, :string, null: false

      # High engagement segment
      add :start_seconds, :integer, null: false
      add :end_seconds, :integer, null: false
      add :suggested_title, :string

      # Engagement data at segment
      add :segment_views, :integer
      add :segment_engagement_rate, :float

      # Source data
      add :retention_curve, :map
      add :engagement_spike_data, :map

      timestamps type: :utc_datetime
    end

    create index(:clip_flags, [:video_id])
    create index(:clip_flags, [:platform])
    create index(:clip_flags, [:video_platform_id])
    create index(:clip_flags, [:start_seconds])
  end
end
