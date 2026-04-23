defmodule ContentForge.Operators.OperatorIdentity do
  @moduledoc """
  Non-phone channel authorization seed for the OpenClaw tool
  surface.

  When a caller invokes a tool through a channel other than
  `"sms"` (for example the OpenClaw CLI), the
  `ContentForge.OpenClawTools.Authorization` helper looks up
  `(product_id, identity)` in this table to resolve the caller's
  role. Only active rows grant access; deactivated rows stay in
  place for audit and so that re-activation later is a simple
  update rather than a re-insert.

  The role column mirrors `ContentForge.Sms.ProductPhone` so both
  resolvers share the same hierarchy (`~w(owner submitter
  viewer)`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @roles ~w(owner submitter viewer)

  schema "operator_identities" do
    field :identity, :string
    field :role, :string
    field :active, :boolean, default: true

    belongs_to :product, ContentForge.Products.Product

    timestamps(type: :utc_datetime)
  end

  @required ~w(product_id identity role)a
  @optional ~w(active)a

  @doc """
  Changeset for `create_identity/1` and generic
  `update_identity/2`.
  """
  def changeset(row, attrs) do
    row
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:role, @roles)
    |> update_change(:identity, &trim_if_binary/1)
    |> validate_length(:identity, min: 1, max: 120)
    |> foreign_key_constraint(:product_id)
    |> unique_constraint(
      [:product_id, :identity],
      name: :operator_identities_product_identity_active_index,
      message: "already registered as an active identity for this product"
    )
  end

  @doc "Changeset that flips `active: false` without touching the role."
  def deactivate_changeset(row), do: change(row, %{active: false})

  defp trim_if_binary(value) when is_binary(value), do: String.trim(value)
  defp trim_if_binary(value), do: value
end
