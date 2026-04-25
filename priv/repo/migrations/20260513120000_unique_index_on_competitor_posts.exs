defmodule ContentForge.Repo.Migrations.UniqueIndexOnCompetitorPosts do
  use Ecto.Migration

  def change do
    # Phase 17.5 backfill importer needs a stable conflict target
    # for idempotent upsert: a competitor's `post_id` (the
    # platform-side id) is unique within an account, so the natural
    # key is `(competitor_account_id, post_id)`. The previous
    # importer-less flow inserted rows without enforcing this,
    # which is fine because the scraper job today does its own
    # in-memory dedupe before calling create_competitor_post.
    create unique_index(:competitor_posts, [:competitor_account_id, :post_id],
             name: :competitor_posts_account_post_id_index
           )
  end
end
