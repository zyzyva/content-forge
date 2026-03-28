defmodule ContentForge.Repo.Migrations.CreateProductSnapshots do
  use Ecto.Migration

  def change do
    create table(:product_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :product_id, references(:products, type: :binary_id, on_delete: :delete_all),
        null: false

      add :snapshot_type, :string, null: false
      add :r2_keys, :jsonb, null: false
      add :token_count, :integer
      add :content_summary, :text

      timestamps type: :utc_datetime
    end

    create index(:product_snapshots, [:product_id])
    create index(:product_snapshots, [:snapshot_type])
  end
end
