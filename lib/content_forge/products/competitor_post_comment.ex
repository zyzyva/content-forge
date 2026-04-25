defmodule ContentForge.Products.CompetitorPostComment do
  @moduledoc """
  Comment captured from a viral competitor post.

  Phase 17.1 introduces this table so the synthesizer (17.4) can
  reason about audience resonance rather than only surface
  patterns. Rows are written by
  `ContentForge.Jobs.CompetitorCommentHarvester` after the parent
  post crosses the viral threshold defined in
  `RESEARCH_LOOP_PLAN.md` Phase 1.

  Idempotency is enforced at the DB layer by the partial unique
  index on `(competitor_post_id, platform_comment_id)`; a re-run
  of the harvester over the same parent inserts zero new rows.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "competitor_post_comments" do
    field :platform_comment_id, :string
    field :author_handle, :string
    field :text, :string
    field :posted_at, :utc_datetime
    field :likes_count, :integer, default: 0
    field :replies_count, :integer, default: 0
    field :retweets_count, :integer, default: 0
    field :views_count, :integer, default: 0
    field :in_reply_to_id, :string
    field :conversation_id, :string
    field :raw_payload, :map

    belongs_to :competitor_post, ContentForge.Products.CompetitorPost

    timestamps(type: :utc_datetime)
  end

  @required ~w(competitor_post_id platform_comment_id)a
  @optional ~w(
    author_handle
    text
    posted_at
    likes_count
    replies_count
    retweets_count
    views_count
    in_reply_to_id
    conversation_id
    raw_payload
  )a

  def changeset(row, attrs) do
    row
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> foreign_key_constraint(:competitor_post_id)
    |> unique_constraint(
      [:competitor_post_id, :platform_comment_id],
      name: :competitor_post_comments_post_id_platform_comment_id_index,
      message: "already captured for this post"
    )
  end
end
