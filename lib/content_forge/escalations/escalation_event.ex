defmodule ContentForge.Escalations.EscalationEvent do
  @moduledoc """
  Phase 16.6 cross-channel escalation row.

  A single row represents one "human attention required" signal
  for a `(product_id, session_id)` pair on a given channel. The
  partial unique index `escalation_events_one_open_per_session_index`
  enforces "at most one open escalation per (product, session)";
  re-escalating a session updates the existing row's `reason`,
  `urgency`, and `holding_reply` rather than creating a duplicate.

  ## Channel namespace

  Mirrors the 16.5 audit channel namespace so escalations can be
  joined cleanly to `tool_invocation_events` rows:

    * `"sms"` - originated from `ContentForge.Sms.escalate_session/3`
    * `"openclaw_<channel>"` - originated from the OpenClaw tool
      surface (e.g. `"openclaw_sms"`, `"openclaw_cli"`)
    * `"mcp"` - originated from the MCP tool surface

  ## PII

  `sender_identity` is hashed (via
  `ContentForge.ToolAudit.hash_pii/1`) when the raw value looks
  like an E.164 phone number; non-phone identities pass through.
  Hashing happens in the `ContentForge.Escalations` context
  before insert.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @urgencies ~w(low normal high)
  @reason_min 1
  @reason_max 2_000

  schema "escalation_events" do
    field :session_id, :string
    field :channel, :string
    field :sender_identity, :string
    field :reason, :string
    field :urgency, :string, default: "normal"
    field :resolved, :boolean, default: false
    field :resolved_at, :utc_datetime_usec
    field :resolved_by, :string
    field :holding_reply, :string

    belongs_to :product, ContentForge.Products.Product

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(product_id session_id channel reason holding_reply)a
  @optional ~w(sender_identity urgency resolved resolved_at resolved_by)a

  @doc """
  Changeset for creating a new escalation event.
  """
  def create_changeset(row, attrs) do
    row
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:urgency, @urgencies)
    |> validate_length(:reason, min: @reason_min, max: @reason_max)
    |> foreign_key_constraint(:product_id)
    |> unique_constraint([:product_id, :session_id],
      name: :escalation_events_one_open_per_session_index
    )
  end

  @doc """
  Changeset for re-escalation (updating an open row's reason +
  urgency + holding_reply + sender_identity in place).
  """
  def reescalate_changeset(row, attrs) do
    row
    |> cast(attrs, ~w(reason urgency holding_reply sender_identity)a)
    |> validate_required([:reason, :holding_reply])
    |> validate_inclusion(:urgency, @urgencies)
    |> validate_length(:reason, min: @reason_min, max: @reason_max)
  end

  @doc """
  Changeset for marking an escalation resolved.
  """
  def resolve_changeset(row, attrs) do
    row
    |> cast(attrs, ~w(resolved resolved_at resolved_by)a)
    |> validate_required([:resolved, :resolved_at])
  end

  @doc "Allowed urgency values."
  def urgencies, do: @urgencies
end
