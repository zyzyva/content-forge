defmodule ContentForge.Sms.ProductPhone do
  @moduledoc """
  Phone number authorized to message a product's SMS inbox.

  Each product maintains its own whitelist. `opt_in_at` is nil until the
  sender confirms consent (either replying YES, submitting a web form,
  or the agency operator recording a verbal opt-in). `active: false`
  disables an otherwise-whitelisted number without losing the
  opt-in-at history.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @roles ~w(owner submitter viewer)
  @opt_in_sources ~w(verbal form reply_yes)

  schema "product_phones" do
    field :phone_number, :string
    field :role, :string
    field :display_label, :string
    field :active, :boolean, default: true
    field :opt_in_at, :utc_datetime_usec
    field :opt_in_source, :string

    belongs_to :product, ContentForge.Products.Product

    timestamps(type: :utc_datetime)
  end

  @required ~w(product_id phone_number role)a
  @optional ~w(display_label active opt_in_at opt_in_source)a

  def changeset(row, attrs) do
    row
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_format(:phone_number, ~r/^\+[1-9]\d{7,14}$/,
      message: "must be in E.164 format, e.g. +15551234567"
    )
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:opt_in_source, @opt_in_sources, allow_nil: true)
    |> foreign_key_constraint(:product_id)
    |> unique_constraint([:product_id, :phone_number],
      name: :product_phones_product_id_phone_number_index,
      message: "phone already whitelisted for this product"
    )
  end

  @doc "Changeset that flips `active: false` without touching the opt-in history."
  def deactivate_changeset(row), do: change(row, %{active: false})
end
