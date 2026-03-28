defmodule ContentForge.Products.CompetitorPost do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "competitor_posts" do
    field :post_id, :string
    field :content, :string
    field :post_url, :string
    field :likes_count, :integer
    field :comments_count, :integer
    field :shares_count, :integer
    field :engagement_score, :float
    field :posted_at, :utc_datetime
    field :raw_data, :map

    belongs_to :competitor_account, ContentForge.Products.CompetitorAccount

    timestamps type: :utc_datetime
  end

  def changeset(post, attrs) do
    post
    |> cast(attrs, [
      :competitor_account_id,
      :post_id,
      :content,
      :post_url,
      :likes_count,
      :comments_count,
      :shares_count,
      :engagement_score,
      :posted_at,
      :raw_data
    ])
    |> validate_required([:competitor_account_id, :content])
  end
end
