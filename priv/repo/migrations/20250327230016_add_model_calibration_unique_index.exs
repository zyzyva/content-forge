defmodule ContentForge.Repo.Migrations.AddModelCalibrationUniqueIndex do
  use Ecto.Migration

  def change do
    create unique_index(:model_calibration, [:model_name, :product_id, :platform, :angle])
  end
end
