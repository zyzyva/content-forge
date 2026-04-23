defmodule ContentForge.Repo.Migrations.CreateOperatorIdentities do
  use Ecto.Migration

  def change do
    # CLI / non-phone channel authorization seed. Each active row maps a
    # (product_id, identity) pair to a role in the ~w(owner submitter
    # viewer) hierarchy. The OpenClaw tool surface uses this table when
    # the caller's channel is not "sms" (the SMS channel already has
    # ProductPhone for role lookup).
    create table(:operator_identities, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :product_id,
          references(:products, type: :binary_id, on_delete: :delete_all),
          null: false

      add :identity, :string, null: false
      add :role, :string, null: false
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create index(:operator_identities, [:product_id])

    # Partial unique index: only one *active* row per (product, identity).
    # Deactivated rows accumulate so a re-seed after deactivation works
    # cleanly. Enforced in the DB so the context helpers can rely on it.
    create unique_index(:operator_identities, [:product_id, :identity],
             where: "active = true",
             name: :operator_identities_product_identity_active_index
           )
  end
end
