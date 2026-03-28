defmodule ContentForge.Repo.Migrations.CreatePublishedPosts do
  use Ecto.Migration

  def change do
    create table(:published_posts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :product_id, references(:products, type: :binary_id, on_delete: :delete_all),
        null: false

      add :draft_id, references(:drafts, type: :binary_id, on_delete: :delete_all), null: false
      add :platform, :string, null: false
      add :platform_post_id, :string
      add :platform_post_url, :string
      add :posted_at, :utc_datetime
      add :engagement_data, :map

      timestamps type: :utc_datetime
    end

    create index(:published_posts, [:product_id])
    create index(:published_posts, [:platform])
    create index(:published_posts, [:posted_at])
    create index(:published_posts, [:draft_id])
  end
end
