defmodule ContentForge.Products.Product do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "products" do
    field :name, :string
    field :repo_url, :string
    field :site_url, :string
    field :voice_profile, :string
    field :publishing_targets, :map

    has_many :blog_webhooks, ContentForge.Products.BlogWebhook

    timestamps type: :utc_datetime
  end

  def changeset(product, attrs) do
    product
    |> cast(attrs, [:name, :repo_url, :site_url, :voice_profile, :publishing_targets])
    |> validate_required([:name, :voice_profile])
    |> validate_format(:repo_url, ~r/^https?:\/\/.*$/, allow_nil: true)
    |> validate_format(:site_url, ~r/^https?:\/\/.*$/, allow_nil: true)
  end
end
