defmodule ContentForge.Repo.Migrations.CreateBlogWebhooks do
  use Ecto.Migration

  def change do
    create table(:blog_webhooks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :url, :string, null: false
      add :hmac_secret, :string
      add :active, :boolean, default: true, null: false

      add :product_id, references(:products, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create index(:blog_webhooks, [:product_id])
  end
end
