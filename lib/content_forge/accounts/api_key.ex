defmodule ContentForge.Accounts.ApiKey do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "api_keys" do
    field :key, :string
    field :label, :string
    field :active, :boolean, default: true

    timestamps type: :utc_datetime
  end

  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:key, :label, :active])
    |> validate_required([:key, :label])
    |> validate_length(:key, min: 32)
  end
end
