defmodule ContentForge.Repo.Migrations.CreateCompetitorPostCommentsAndColumns do
  use Ecto.Migration

  def change do
    # Phase 17.1 corpus enrichment.
    # Two coupled changes ship together because the comment harvester
    # needs `competitor_posts.conversation_id` to know which thread to
    # pull and `views_count` is the absolute-ceiling axis of the viral
    # threshold from RESEARCH_LOOP_PLAN Phase 1.

    alter table(:competitor_posts) do
      add :views_count, :integer, null: false, default: 0
      add :conversation_id, :string
    end

    create index(:competitor_posts, [:conversation_id])

    # Comment thread corpus. FK cascades on delete so when a competitor
    # post is removed (e.g., account deletion) its captured comments go
    # with it. The unique index on (post, platform_comment_id) is what
    # makes the harvester re-run idempotent.
    create table(:competitor_post_comments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :competitor_post_id,
          references(:competitor_posts, type: :binary_id, on_delete: :delete_all),
          null: false

      add :platform_comment_id, :string, null: false
      add :author_handle, :string
      add :text, :text
      add :posted_at, :utc_datetime
      add :likes_count, :integer, null: false, default: 0
      add :replies_count, :integer, null: false, default: 0
      add :retweets_count, :integer, null: false, default: 0
      add :views_count, :integer, null: false, default: 0
      add :in_reply_to_id, :string
      add :conversation_id, :string
      add :raw_payload, :map

      timestamps(type: :utc_datetime)
    end

    create index(:competitor_post_comments, [:competitor_post_id])

    create unique_index(
             :competitor_post_comments,
             [:competitor_post_id, :platform_comment_id],
             name: :competitor_post_comments_post_id_platform_comment_id_index
           )
  end
end
