defmodule ContentForge.Sms.ConversationSession do
  @moduledoc """
  Per-(product, phone_number) conversation state.

  The session is a small state machine driven by inbound SMS events.
  `last_message_at` is refreshed on every touch; a session is considered
  stale if `last_message_at + inactive_after_seconds` is in the past.
  Stale sessions transition to `"idle"` via `ContentForge.Sms.expire_stale_sessions/1`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @states ~w(idle waiting_for_upload waiting_for_context status_query)

  schema "conversation_sessions" do
    field :phone_number, :string
    field :state, :string, default: "idle"
    field :last_message_at, :utc_datetime_usec
    field :inactive_after_seconds, :integer, default: 3600

    belongs_to :product, ContentForge.Products.Product

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(product_id phone_number state)a
  @optional ~w(last_message_at inactive_after_seconds)a

  def changeset(row, attrs) do
    row
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_format(:phone_number, ~r/^\+[1-9]\d{7,14}$/,
      message: "must be in E.164 format, e.g. +15551234567"
    )
    |> validate_inclusion(:state, @states)
    |> validate_number(:inactive_after_seconds, greater_than: 0)
    |> foreign_key_constraint(:product_id)
    |> unique_constraint([:product_id, :phone_number],
      name: :conversation_sessions_product_id_phone_number_index,
      message: "session already exists for this (product, phone)"
    )
  end

  @doc "Returns the list of valid session states."
  def states, do: @states
end
