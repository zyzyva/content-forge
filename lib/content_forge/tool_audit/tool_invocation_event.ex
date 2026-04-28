defmodule ContentForge.ToolAudit.ToolInvocationEvent do
  @moduledoc """
  Phase 16.5 audit row for every tool invocation across every
  channel (OpenClaw tool surface + MCP server).

  Insert-only. `product_id` is nullable + nilify_all so the audit
  row survives product deletion and so tool calls that fail
  before resolving a product still leave a forensic trace.

  ## Fields

    * `tool_name` - registered tool name (e.g.
      `"create_upload_link"` or `"cf_create_product"`).
    * `channel` - one of `"openclaw_sms"`, `"openclaw_cli"`,
      `"openclaw_unknown"`, `"mcp"`. The OpenClaw channels reflect
      `ctx[:channel]` from the controller; MCP rows are always
      `"mcp"`.
    * `sender_identity` - PII-hashed when the raw value looks
      like a phone number; passed through otherwise (e.g.
      `"cli:ops"`, `"mcp"`). Hashing happens in
      `ContentForge.ToolAudit` before insert; the schema stores
      whatever the writer provides.
    * `params` - tool params with PII-bearing values redacted to
      their SHA-256 hash. The schema does not enforce redaction;
      callers must redact via `ContentForge.ToolAudit.redact/2`.
    * `result_status` - one of `"ok"`, `"error"`,
      `"confirmation_required"`, `"unknown_tool"`.
    * `result_summary` - short error reason for `error`/`unknown_tool`
      rows; nil for `ok`. Populated by
      `ContentForge.ToolAudit.normalize_result/1`.
    * `duration_ms` - tool wall-clock duration in milliseconds.
    * `invoked_at` - timestamp the tool started executing.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @result_statuses ~w(ok error confirmation_required unknown_tool)

  schema "tool_invocation_events" do
    field :tool_name, :string
    field :channel, :string
    field :sender_identity, :string
    field :params, :map, default: %{}
    field :result_status, :string
    field :result_summary, :string
    field :duration_ms, :integer
    field :invoked_at, :utc_datetime_usec

    belongs_to :product, ContentForge.Products.Product

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(tool_name channel result_status invoked_at)a
  @optional ~w(product_id sender_identity params result_summary duration_ms)a

  def changeset(row, attrs) do
    row
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:result_status, @result_statuses)
    |> foreign_key_constraint(:product_id)
  end

  @doc "List of allowed result_status values for filter validation."
  def result_statuses, do: @result_statuses
end
