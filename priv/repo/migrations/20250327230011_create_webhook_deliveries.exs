defmodule ContentForge.Repo.Migrations.CreateWebhookDeliveries do
  use Ecto.Migration

  def change do
    create table(:webhook_deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :product_id, references(:products, type: :binary_id, on_delete: :delete_all),
        null: false

      add :blog_webhook_id, references(:blog_webhooks, type: :binary_id, on_delete: :delete_all),
        null: false

      add :draft_id, references(:drafts, type: :binary_id, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "pending"
      add :delivered_at, :utc_datetime
      add :error, :string

      timestamps(type: :utc_datetime)
    end

    create index(:webhook_deliveries, [:product_id])
    create index(:webhook_deliveries, [:blog_webhook_id])
    create index(:webhook_deliveries, [:draft_id])
    create index(:webhook_deliveries, [:status])
  end
end
