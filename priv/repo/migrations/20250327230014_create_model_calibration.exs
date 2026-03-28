defmodule ContentForge.Repo.Migrations.CreateModelCalibration do
  use Ecto.Migration

  def change do
    create table(:model_calibration, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :model_name, :string, null: false

      add :product_id, references(:products, type: :binary_id, on_delete: :delete_all),
        null: false

      add :platform, :string, null: false
      add :angle, :string
      add :avg_score_delta, :float
      add :sample_count, :integer
      add :last_updated, :utc_datetime

      timestamps type: :utc_datetime
    end

    create index(:model_calibration, [:model_name])
    create index(:model_calibration, [:product_id])
    create index(:model_calibration, [:model_name, :product_id, :platform])
    create unique_index(:model_calibration, [:model_name, :product_id, :platform, :angle])
  end
end
