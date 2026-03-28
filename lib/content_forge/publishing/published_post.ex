defmodule ContentForge.Publishing.PublishedPost do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "published_posts" do
    field :platform, :string
    field :platform_post_id, :string
    field :platform_post_url, :string
    field :posted_at, :utc_datetime
    field :engagement_data, :map

    belongs_to :product, ContentForge.Products.Product
    belongs_to :draft, ContentForge.ContentGeneration.Draft

    timestamps type: :utc_datetime
  end

  def changeset(published_post, attrs) do
    published_post
    |> cast(attrs, [
      :product_id,
      :draft_id,
      :platform,
      :platform_post_id,
      :platform_post_url,
      :posted_at,
      :engagement_data
    ])
    |> validate_required([:product_id, :draft_id, :platform])
    |> validate_inclusion(:platform, ~w(twitter linkedin reddit facebook instagram))
  end
end
