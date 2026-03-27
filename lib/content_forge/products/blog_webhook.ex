defmodule ContentForge.Products.BlogWebhook do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "blog_webhooks" do
    field :url, :string
    field :hmac_secret, :string
    field :active, :boolean, default: true

    belongs_to :product, ContentForge.Products.Product

    timestamps type: :utc_datetime
  end

  def changeset(webhook, attrs) do
    webhook
    |> cast(attrs, [:url, :hmac_secret, :active, :product_id])
    |> validate_required([:url, :product_id])
    |> validate_format(:url, ~r/^https?:\/\/.*$/)
    |> assoc_constraint(:product)
  end
end
