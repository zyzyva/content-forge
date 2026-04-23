defmodule ContentForge.Repo.Migrations.CreateVideoJobs do
  use Ecto.Migration

  def change do
    create table(:video_jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :draft_id,
          references(:drafts, type: :binary_id, on_delete: :delete_all),
          null: false

      add :product_id,
          references(:products, type: :binary_id, on_delete: :delete_all),
          null: false

      add :status, :string, null: false, default: "script_approved"

      add :per_step_r2_keys, :map

      add :error, :text

      add :feature_flag, :boolean, default: true

      timestamps(type: :utc_datetime)
    end

    create index(:video_jobs, [:draft_id])
    create index(:video_jobs, [:product_id])
    create index(:video_jobs, [:status])
  end
end
