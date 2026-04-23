defmodule ContentForge.Publishing.WebhookDelivery do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "webhook_deliveries" do
    field :status, :string
    field :delivered_at, :utc_datetime
    field :error, :string

    belongs_to :product, ContentForge.Products.Product
    belongs_to :blog_webhook, ContentForge.Products.BlogWebhook
    belongs_to :draft, ContentForge.ContentGeneration.Draft

    timestamps type: :utc_datetime
  end

  def changeset(webhook_delivery, attrs) do
    webhook_delivery
    |> cast(attrs, [
      :product_id,
      :blog_webhook_id,
      :draft_id,
      :status,
      :delivered_at,
      :error
    ])
    |> validate_required([:product_id, :blog_webhook_id, :draft_id, :status])
    |> validate_inclusion(:status, ~w(pending success failed))
    |> assoc_constraint(:product)
    |> assoc_constraint(:blog_webhook)
    |> assoc_constraint(:draft)
  end

  def pending_status, do: "pending"
  def success_status, do: "success"
  def failed_status, do: "failed"
end
