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

  alias ContentForge.OpenClawTools.AddTagToAsset
  alias ContentForge.OpenClawTools.ApproveDraft
  alias ContentForge.OpenClawTools.CompetitorIntelSummary
  alias ContentForge.OpenClawTools.CreateAssetBundle
  alias ContentForge.OpenClawTools.CreateUploadLink
  alias ContentForge.OpenClawTools.DraftStatus
  alias ContentForge.OpenClawTools.ListRecentAssets
  alias ContentForge.OpenClawTools.RecordMemory
  alias ContentForge.OpenClawTools.UpcomingSchedule

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
    "approve_draft" => ApproveDraft
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
  so the controller can respond 404.
  """
  @spec dispatch(String.t(), ctx(), map()) :: result()
  def dispatch(tool_name, ctx, params) when is_binary(tool_name) and is_map(params) do
    case lookup_tool(tool_name) do
      nil -> {:error, :unknown_tool}
      module -> module.call(ctx, params)
    end
  end

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
