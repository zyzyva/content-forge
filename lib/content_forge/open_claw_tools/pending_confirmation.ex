defmodule ContentForge.OpenClawTools.PendingConfirmation do
  @moduledoc """
  Persistence for the two-turn heavy-write confirmation protocol
  (Phase 16.4).

  A row lives from the moment a heavy-write tool asks for
  confirmation until the user's echo phrase lands on a follow-up
  call. The second turn marks `consumed_at`; rows are never
  deleted so the audit trail stays append-only.

  Invariants:

    * At most one live row per `(session_id, echo_phrase)` - the
      partial unique index on `consumed_at IS NULL` enforces it.
    * `params_hash` is a SHA-256 of the canonicalized params from
      the first-turn call, so replaying a phrase against
      different params is distinguishable as a mismatch without
      re-executing the tool.
    * `preview` is whatever map the tool supplied on turn one so
      the agent can replay context verbatim if asked.

  Field notes:

    * `session_id` comes from the invocation ctx, not params; a
      spoofed `session_id` in params would not match the ctx.
    * `expires_at` defaults to `now + confirmation_expiry_seconds`
      (300 by default); the context computes it.
    * `consumed_at` is `nil` until the second-turn confirm lands.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "pending_confirmations" do
    field :session_id, :string
    field :tool_name, :string
    field :params_hash, :string
    field :echo_phrase, :string
    field :preview, :map, default: %{}
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(session_id tool_name params_hash echo_phrase expires_at)a
  @optional ~w(preview consumed_at)a

  @doc "Changeset used when `Confirmation.request/4` inserts a fresh row."
  def insert_changeset(row, attrs) do
    row
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:session_id, min: 1, max: 255)
    |> validate_length(:tool_name, min: 1, max: 80)
    |> validate_length(:echo_phrase, min: 1, max: 120)
    |> validate_length(:params_hash, min: 1, max: 128)
    |> unique_constraint(
      [:session_id, :echo_phrase],
      name: :pending_confirmations_session_phrase_active_index,
      message: "phrase already live for this session"
    )
  end
end
