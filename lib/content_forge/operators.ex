defmodule ContentForge.Operators do
  @moduledoc """
  Context for non-phone channel authorization seeds.

  Every non-SMS invocation of an OpenClaw tool that writes (16.3+)
  looks up the caller's role by `(identity, product_id)` in the
  `operator_identities` table via `lookup_active_identity/2`. The
  table is the CLI / Telegram / future-channel equivalent of the
  SMS-specific `ProductPhone` whitelist.

  Only active rows grant access. Deactivation via
  `deactivate_identity/1` preserves the row so a later re-seed
  (higher-level `create_identity/1`) can re-authorize the same
  identifier without conflicting with the partial unique index on
  the table.
  """

  import Ecto.Query

  alias ContentForge.Operators.OperatorIdentity
  alias ContentForge.Repo

  @doc "Creates a new operator identity. Returns `{:ok, row}` or `{:error, changeset}`."
  @spec create_identity(map()) ::
          {:ok, OperatorIdentity.t()} | {:error, Ecto.Changeset.t()}
  def create_identity(attrs) when is_map(attrs) do
    %OperatorIdentity{}
    |> OperatorIdentity.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Looks up the active `%OperatorIdentity{}` row for the given
  `(identity, product_id)` pair. Returns nil when no active row
  exists, which covers "not seeded", "deactivated", and
  "registered under a different product".
  """
  @spec lookup_active_identity(String.t(), Ecto.UUID.t()) :: OperatorIdentity.t() | nil
  def lookup_active_identity(identity, product_id)
      when is_binary(identity) and is_binary(product_id) do
    Repo.one(
      from(o in OperatorIdentity,
        where:
          o.identity == ^identity and
            o.product_id == ^product_id and
            o.active == true
      )
    )
  end

  @doc """
  Lists every identity (active or deactivated) registered for the
  given product. Active rows come first so seed dashboards render
  current permissions on top; ties break on `inserted_at`.
  """
  @spec list_identities_for_product(Ecto.UUID.t()) :: [OperatorIdentity.t()]
  def list_identities_for_product(product_id) when is_binary(product_id) do
    Repo.all(
      from(o in OperatorIdentity,
        where: o.product_id == ^product_id,
        order_by: [desc: o.active, asc: o.inserted_at]
      )
    )
  end

  @doc "Deactivates an identity without deleting the row."
  @spec deactivate_identity(OperatorIdentity.t()) ::
          {:ok, OperatorIdentity.t()} | {:error, Ecto.Changeset.t()}
  def deactivate_identity(%OperatorIdentity{} = row) do
    row
    |> OperatorIdentity.deactivate_changeset()
    |> Repo.update()
  end
end
