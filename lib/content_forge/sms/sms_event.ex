defmodule ContentForge.Sms.SmsEvent do
  @moduledoc """
  Audit row for every inbound or outbound SMS the system sees.

  The row is insert-only in the happy path: no update path is
  exposed from the context. `product_id` is nullable so rejected
  messages from unknown numbers still land in the log, and the FK
  uses `on_delete: :nilify_all` so the audit row survives a product
  deletion.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @directions ~w(inbound outbound)
  @statuses ~w(received sent delivered failed rejected_unknown_number rejected_rate_limit unsupported_media stop_received start_received)

  schema "sms_events" do
    field :phone_number, :string
    field :direction, :string
    field :body, :string
    field :media_urls, {:array, :string}, default: []
    field :status, :string
    field :twilio_sid, :string

    belongs_to :product, ContentForge.Products.Product

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(phone_number direction status)a
  @optional ~w(product_id body media_urls twilio_sid)a

  def changeset(row, attrs) do
    row
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_format(:phone_number, ~r/^\+[1-9]\d{7,14}$/,
      message: "must be in E.164 format, e.g. +15551234567"
    )
    |> validate_inclusion(:direction, @directions)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:product_id)
  end
end
