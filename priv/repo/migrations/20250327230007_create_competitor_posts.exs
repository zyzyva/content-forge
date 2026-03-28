defmodule ContentForge.Repo.Migrations.CreateCompetitorPosts do
  use Ecto.Migration

  def change do
    create table(:competitor_posts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :competitor_account_id,
          references(:competitor_accounts, type: :binary_id, on_delete: :delete_all), null: false

      add :post_id, :string
      add :content, :text
      add :post_url, :string
      add :likes_count, :integer
      add :comments_count, :integer
      add :shares_count, :integer
      add :engagement_score, :float
      add :posted_at, :utc_datetime
      add :raw_data, :jsonb

      timestamps type: :utc_datetime
    end

    create index(:competitor_posts, [:competitor_account_id])
    create index(:competitor_posts, [:engagement_score])
  end
end
