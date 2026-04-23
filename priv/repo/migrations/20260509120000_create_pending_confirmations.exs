defmodule ContentForge.Repo.Migrations.CreatePendingConfirmations do
  use Ecto.Migration

  def change do
    # Two-turn confirmation state for heavy-write OpenClaw tools
    # (16.4). Row lifecycle: insert on the first turn (agent asks
    # user for echo phrase), update `consumed_at` on the second
    # turn (agent supplies the phrase and the tool executes).
    # Rows are never deleted so the audit trail is append-only;
    # expiry is a column, not a cron-driven reap.
    create table(:pending_confirmations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :session_id, :string, null: false
      add :tool_name, :string, null: false
      add :params_hash, :string, null: false
      add :echo_phrase, :string, null: false
      add :preview, :map, null: false, default: %{}
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # Partial unique: at most one live (unconsumed) row per
    # (session, phrase). Enforces the "single-use" invariant at
    # the DB level and lets the context short-circuit double
    # consumes via an atomic UPDATE ... WHERE consumed_at IS NULL.
    create unique_index(:pending_confirmations, [:session_id, :echo_phrase],
             where: "consumed_at IS NULL",
             name: :pending_confirmations_session_phrase_active_index
           )

    # Composite for the idempotent-request lookup: given
    # (session, tool, params_hash), can we find a still-live
    # pending row? `expires_at > NOW()` is NOT part of the index
    # predicate (NOW() is stable, not immutable, so Postgres
    # refuses it). The context filters by expires_at at query
    # time; the partial on consumed_at is what keeps the index
    # small.
    create index(:pending_confirmations, [:session_id, :tool_name, :params_hash],
             where: "consumed_at IS NULL",
             name: :pending_confirmations_session_tool_hash_live_index
           )
  end
end
