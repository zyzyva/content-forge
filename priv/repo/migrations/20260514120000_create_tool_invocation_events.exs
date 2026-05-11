defmodule ContentForge.Repo.Migrations.CreateToolInvocationEvents do
  use Ecto.Migration

  def change do
    # Phase 16.5 unified tool-invocation audit. Insert-only audit
    # row covering every tool call across every channel
    # (`openclaw_*` tool surface + the MCP server). Separate from
    # `sms_events` because the surface is multi-channel and the
    # row shape is generic.
    #
    # `product_id` is nullable + nilify_all so the audit row
    # survives a product deletion (forensics) and so attempted
    # tool calls that do not resolve to a product still log.
    create table(:tool_invocation_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :product_id,
          references(:products, type: :binary_id, on_delete: :nilify_all)

      add :tool_name, :string, null: false
      add :channel, :string, null: false
      add :sender_identity, :string
      add :params, :map, null: false, default: %{}
      add :result_status, :string, null: false
      add :result_summary, :string
      add :duration_ms, :integer
      add :invoked_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:tool_invocation_events, [:product_id, :invoked_at])
    create index(:tool_invocation_events, [:tool_name])
    create index(:tool_invocation_events, [:channel])
    create index(:tool_invocation_events, [:invoked_at])
  end
end
