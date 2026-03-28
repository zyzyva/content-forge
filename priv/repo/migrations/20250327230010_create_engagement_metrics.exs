defmodule ContentForge.Repo.Migrations.CreateEngagementMetrics do
  use Ecto.Migration

  def change do
    create table(:engagement_metrics, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :product_id, references(:products, type: :binary_id, on_delete: :delete_all),
        null: false

      add :platform, :string, null: false
      add :hour_of_day, :integer, null: false
      add :day_of_week, :integer, null: false
      add :total_posts, :integer, default: 0
      add :total_engagement, :integer, default: 0
      add :avg_engagement, :float
      add :last_calculated_at, :utc_datetime

      timestamps type: :utc_datetime
    end

    create index(:engagement_metrics, [:product_id, :platform])
    create index(:engagement_metrics, [:product_id, :platform, :hour_of_day])
    create index(:engagement_metrics, [:product_id, :platform, :day_of_week])

    create unique_index(:engagement_metrics, [:product_id, :platform, :hour_of_day, :day_of_week],
             name: "engagement_metrics_unique_slot"
           )
  end
end
