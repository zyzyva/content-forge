defmodule ContentForge.Repo.Migrations.CreateCompetitorAccounts do
  use Ecto.Migration

  def change do
    create table(:competitor_accounts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :product_id, references(:products, type: :binary_id, on_delete: :delete_all),
        null: false

      add :platform, :string, null: false
      add :handle, :string, null: false
      add :url, :string
      add :active, :boolean, default: true, null: false

      timestamps type: :utc_datetime
    end

    create index(:competitor_accounts, [:product_id])
    create index(:competitor_accounts, [:platform])
  end
end
