defmodule ContentForge.OpenClawToolsDispatchEscalationTest do
  @moduledoc """
  Phase 16.6 OpenClaw dispatcher hook: short-circuits subsequent
  tool calls on a session with an open escalation. Two exemptions:
  `escalate_to_human` itself, and (the MCP-level)
  `cf_recent_scoreboard` (covered in the MCP test file). An
  expired or resolved escalation does not block.
  """

  use ContentForge.DataCase, async: false

  alias ContentForge.Escalations
  alias ContentForge.OpenClawTools
  alias ContentForge.Products
  alias ContentForge.Repo
  alias ContentForge.ToolAudit.ToolInvocationEvent

  defmodule StubTool do
    @moduledoc false
    def call(_ctx, _params), do: {:ok, %{ran: true}}
  end

  setup do
    original = Application.get_env(:content_forge, :extra_open_claw_tools, %{})

    Application.put_env(:content_forge, :extra_open_claw_tools, %{
      "stub_dispatch_tool" => StubTool
    })

    on_exit(fn ->
      Application.put_env(:content_forge, :extra_open_claw_tools, original)
    end)

    {:ok, product} =
      Products.create_product(%{
        name: "Dispatch Esc Product #{System.unique_integer()}",
        voice_profile: "professional"
      })

    %{product: product}
  end

  defp open_escalation!(product, session_id) do
    {:ok, event} =
      Escalations.create_or_update_open(%{
        product_id: product.id,
        session_id: session_id,
        channel: "openclaw_cli",
        reason: "user wants a human",
        holding_reply: "Hold tight - someone will reach out."
      })

    event
  end

  test "open escalation short-circuits subsequent tool calls with the holding reply", %{
    product: product
  } do
    open_escalation!(product, "sess-block-1")

    ctx = %{channel: "cli", session_id: "sess-block-1"}

    assert {:error, {:escalated, %{holding_reply: reply}}} =
             OpenClawTools.dispatch("stub_dispatch_tool", ctx, %{"product_id" => product.id})

    assert reply == "Hold tight - someone will reach out."

    [event] = recent_audit("stub_dispatch_tool")
    assert event.result_status == "blocked_escalated"
    assert event.result_summary == "escalated"
  end

  test "escalate_to_human itself is exempt from the short-circuit", %{product: product} do
    open_escalation!(product, "sess-esc-1")

    {:ok, _} =
      ContentForge.Sms.create_phone(%{
        product_id: product.id,
        phone_number: "+15554440001",
        role: "viewer",
        active: true
      })

    ctx = %{channel: "sms", sender_identity: "+15554440001", session_id: "sess-esc-1"}

    assert {:ok, _result} =
             OpenClawTools.dispatch("escalate_to_human", ctx, %{
               "product" => product.id,
               "reason" => "still not handled"
             })
  end

  test "expired escalation (older than the configured window) does not block", %{
    product: product
  } do
    event = open_escalation!(product, "sess-expired-1")

    stale_at = DateTime.add(DateTime.utc_now(), -7200, :second)

    Repo.update_all(
      from(e in ContentForge.Escalations.EscalationEvent, where: e.id == ^event.id),
      set: [inserted_at: stale_at]
    )

    Application.put_env(:content_forge, :escalations, session_window_seconds: 3600)

    on_exit(fn -> Application.delete_env(:content_forge, :escalations) end)

    ctx = %{channel: "cli", session_id: "sess-expired-1"}

    assert {:ok, %{ran: true}} =
             OpenClawTools.dispatch("stub_dispatch_tool", ctx, %{"product_id" => product.id})
  end

  test "resolved escalation does not block", %{product: product} do
    event = open_escalation!(product, "sess-resolved-1")
    {:ok, _} = Escalations.mark_resolved(event, "operator-x")

    ctx = %{channel: "cli", session_id: "sess-resolved-1"}

    assert {:ok, %{ran: true}} =
             OpenClawTools.dispatch("stub_dispatch_tool", ctx, %{"product_id" => product.id})
  end

  test "escalation on a different session does not block this session", %{product: product} do
    open_escalation!(product, "sess-other")

    ctx = %{channel: "cli", session_id: "sess-mine"}

    assert {:ok, %{ran: true}} =
             OpenClawTools.dispatch("stub_dispatch_tool", ctx, %{"product_id" => product.id})
  end

  defp recent_audit(tool_name) do
    import Ecto.Query

    ToolInvocationEvent
    |> where([e], e.tool_name == ^tool_name)
    |> order_by([e], desc: e.invoked_at)
    |> Repo.all()
  end
end
