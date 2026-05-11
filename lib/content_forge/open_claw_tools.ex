defmodule ContentForge.OpenClawTools do
  @moduledoc """
  Dispatch entry point for OpenClaw agent tool invocations.

  The OpenClaw gateway registers Content Forge tools via the Node
  plugin at `~/.openclaw/plugins/content-forge/index.js`. When
  the agent calls a tool, the plugin POSTs to
  `/api/v1/openclaw/tools/:tool_name`. The controller
  (`ContentForgeWeb.OpenClawToolController`) authenticates via
  the `X-OpenClaw-Tool-Secret` header and delegates to this
  module's `dispatch/3`.

  Each tool is its own module under
  `ContentForge.OpenClawTools.<Name>` implementing a single
  `call/2` callback:

      @callback call(ctx :: map(), params :: map()) ::
                  {:ok, map()} | {:error, term()}

  The `ctx` map carries invocation metadata from OpenClaw:
  `:session_id`, `:channel` (`"sms" | "cli" | ...`), and
  `:sender_identity` (phone number, operator id, etc.).

  Phase 16.1 ships the first tool: `create_upload_link`. Phase
  16.2 adds four read-only tools (`list_recent_assets`,
  `draft_status`, `upcoming_schedule`,
  `competitor_intel_summary`). Phase 16.3c adds two light-write
  tools (`create_asset_bundle`, `add_tag_to_asset`). Phase 16.3d
  adds `record_memory`. Phase 16.4b adds the first heavy-write
  tool behind the 16.4a confirmation envelope: `approve_draft`.
  The remaining 16.4+ slices add `schedule_reminder_change`,
  `generate_drafts_from_bundle`, escalation, and audit surfacing.
  """

  alias ContentForge.Escalations
  alias ContentForge.Escalations.EscalationEvent
  alias ContentForge.OpenClawTools.AddTagToAsset
  alias ContentForge.OpenClawTools.ApproveDraft
  alias ContentForge.OpenClawTools.CompetitorIntelSummary
  alias ContentForge.OpenClawTools.CreateAssetBundle
  alias ContentForge.OpenClawTools.CreateUploadLink
  alias ContentForge.OpenClawTools.DraftStatus
  alias ContentForge.OpenClawTools.EscalateToHuman
  alias ContentForge.OpenClawTools.GenerateDraftsFromBundle
  alias ContentForge.OpenClawTools.ListRecentAssets
  alias ContentForge.OpenClawTools.ProductResolver
  alias ContentForge.OpenClawTools.RecordMemory
  alias ContentForge.OpenClawTools.ScheduleReminderChange
  alias ContentForge.OpenClawTools.UpcomingSchedule
  alias ContentForge.ToolAudit

  @type ctx :: %{
          optional(:session_id) => String.t(),
          optional(:channel) => String.t(),
          optional(:sender_identity) => String.t()
        }

  @type result ::
          {:ok, map()}
          | {:ok, :confirmation_required, map()}
          | {:error, :unknown_tool | term()}

  @tools %{
    "create_upload_link" => CreateUploadLink,
    "list_recent_assets" => ListRecentAssets,
    "draft_status" => DraftStatus,
    "upcoming_schedule" => UpcomingSchedule,
    "competitor_intel_summary" => CompetitorIntelSummary,
    "create_asset_bundle" => CreateAssetBundle,
    "add_tag_to_asset" => AddTagToAsset,
    "record_memory" => RecordMemory,
    "approve_draft" => ApproveDraft,
    "schedule_reminder_change" => ScheduleReminderChange,
    "generate_drafts_from_bundle" => GenerateDraftsFromBundle,
    "escalate_to_human" => EscalateToHuman
  }

  @doc """
  Returns the set of registered tool names. Useful for tests
  and for the Node plugin (if it ever wants to self-introspect
  the available tools via a meta endpoint).
  """
  @spec registered_tools() :: [String.t()]
  def registered_tools, do: Map.keys(@tools)

  @doc """
  Dispatches a tool invocation to the matching module.

  Returns `{:error, :unknown_tool}` for unregistered tool names
  so the controller can respond 404. Phase 16.5 wraps every
  invocation (including unknown-tool short-circuits) with a
  `ToolAudit.log_invocation/5` call so the dashboard
  surface and REST API see every attempted call. Phase 16.6 adds
  a pre-check that short-circuits with
  `{:error, {:escalated, %{holding_reply: ...}}}` when the
  current `(product_id, session_id)` has an open escalation.
  Two exemptions: `escalate_to_human` itself never short-circuits
  (re-escalation must always succeed), and `cf_recent_scoreboard`
  is operator-facing and lives on the MCP surface.
  """
  @spec dispatch(String.t(), ctx(), map()) :: result()
  def dispatch(tool_name, ctx, params) when is_binary(tool_name) and is_map(params) do
    audit_ctx = put_channel_namespace(ctx, "openclaw")
    started_at = System.monotonic_time(:millisecond)
    invoked_at = DateTime.utc_now()

    result = run_dispatch(tool_name, ctx, params)
    duration_ms = System.monotonic_time(:millisecond) - started_at

    _ =
      ToolAudit.log_invocation(tool_name, audit_ctx, params, result, %{
        duration_ms: duration_ms,
        invoked_at: invoked_at
      })

    result
  end

  defp run_dispatch(tool_name, ctx, params) do
    case lookup_tool(tool_name) do
      nil ->
        {:error, :unknown_tool}

      module ->
        case escalation_block(tool_name, ctx, params) do
          {:block, holding_reply} -> {:error, {:escalated, %{holding_reply: holding_reply}}}
          :pass -> module.call(ctx, params)
        end
    end
  end

  defp escalation_block("escalate_to_human", _ctx, _params), do: :pass

  defp escalation_block(_tool_name, ctx, params) do
    with {:ok, product_id} <- best_effort_product_id(params, ctx),
         %EscalationEvent{} = event <-
           Escalations.find_open(product_id, session_id_for(ctx),
             max_age_seconds: escalation_window()
           ) do
      {:block, event.holding_reply}
    else
      _ -> :pass
    end
  end

  defp best_effort_product_id(params, ctx) do
    cond do
      is_binary(params["product_id"]) and params["product_id"] != "" ->
        {:ok, params["product_id"]}

      is_binary(params["product"]) and params["product"] != "" ->
        case ProductResolver.resolve(ctx, params) do
          {:ok, product} -> {:ok, product.id}
          _ -> :error
        end

      true ->
        case ProductResolver.resolve(ctx, params) do
          {:ok, product} -> {:ok, product.id}
          _ -> :error
        end
    end
  end

  defp session_id_for(ctx) do
    case Map.get(ctx, :session_id) do
      sid when is_binary(sid) and sid != "" -> sid
      _ -> "openclaw-#{Map.get(ctx, :channel) || "unknown"}"
    end
  end

  defp escalation_window do
    Application.get_env(:content_forge, :escalations, [])
    |> Keyword.get(:session_window_seconds, 86_400)
  end

  defp put_channel_namespace(ctx, prefix) do
    raw = Map.get(ctx, :channel)
    Map.put(ctx, :channel, namespaced_channel(prefix, raw))
  end

  defp namespaced_channel(prefix, nil), do: "#{prefix}_unknown"
  defp namespaced_channel(prefix, ""), do: "#{prefix}_unknown"
  defp namespaced_channel(prefix, channel) when is_binary(channel), do: "#{prefix}_#{channel}"

  # Tests register temporary stub tools via
  # `Application.put_env(:content_forge, :extra_open_claw_tools,
  # %{"name" => Module})`. Prod never sets this key so the
  # fallback path is the compile-time @tools map.
  defp lookup_tool(tool_name) do
    :content_forge
    |> Application.get_env(:extra_open_claw_tools, %{})
    |> Map.get(tool_name) || Map.get(@tools, tool_name)
  end
end
