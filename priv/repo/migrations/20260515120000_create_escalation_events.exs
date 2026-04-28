defmodule ContentForge.Repo.Migrations.CreateEscalationEvents do
  use Ecto.Migration

  def change do
    # Phase 16.6 generic escalation event. Cross-channel
    # source-of-record for any "human attention required" signal:
    # SMS (via the existing 14.5 path), OpenClaw tools, MCP, and
    # future channels. The dispatcher hooks read this table on
    # every tool call to decide whether to short-circuit.
    #
    # `product_id` uses `nilify_all` so a product deletion leaves
    # the audit trail intact (operators may need to see what was
    # escalated even after a product is removed).
    create table(:escalation_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :product_id,
          references(:products, type: :binary_id, on_delete: :nilify_all),
          null: false

      add :session_id, :string, null: false
      add :channel, :string, null: false
      add :sender_identity, :string
      add :reason, :text, null: false
      add :urgency, :string, null: false, default: "normal"
      add :resolved, :boolean, null: false, default: false
      add :resolved_at, :utc_datetime_usec
      add :resolved_by, :string
      add :holding_reply, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:escalation_events, [:product_id, :inserted_at])
    create index(:escalation_events, [:resolved, :inserted_at])

    # At most one open escalation per (product, session). A
    # re-escalation on an already-open session updates the existing
    # row's reason / urgency / inserted_at rather than inserting a
    # second open row. The partial filter keeps the constraint
    # quiet for resolved historical rows.
    create unique_index(:escalation_events, [:product_id, :session_id],
             where: "resolved = false",
             name: :escalation_events_one_open_per_session_index
           )
  end
end
