defmodule ContentForgeMCP.ServerDispatchEscalationTest do
  @moduledoc """
  Phase 16.6 MCP dispatcher hook: short-circuits subsequent
  cf_* tool calls on a product with an open escalation
  (session_id = "mcp" since MCP has no client session concept).
  Two exemptions: a (future) escalate_to_human MCP tool name,
  and `cf_recent_scoreboard` (operator-facing read).
  """

  use ContentForge.DataCase, async: false

  alias ContentForge.Escalations
  alias ContentForge.Products
  alias ContentForge.Repo
  alias ContentForge.ToolAudit.ToolInvocationEvent
  alias ContentForgeMCP.Server

  setup do
    {:ok, product} =
      Products.create_product(%{
        name: "MCP Esc Product #{System.unique_integer()}",
        voice_profile: "professional"
      })

    %{product: product}
  end

  defp open_mcp_escalation!(product) do
    {:ok, event} =
      Escalations.create_or_update_open(%{
        product_id: product.id,
        session_id: "mcp",
        channel: "mcp",
        reason: "operator escalation",
        holding_reply: "Awaiting a human."
      })

    event
  end

  test "open MCP escalation short-circuits a regular cf_* call with the holding reply", %{
    product: product
  } do
    open_mcp_escalation!(product)

    {:error, %{code: "escalated", message: msg}} =
      Server.handle_tool_call("cf_list_competitors", %{"product_id" => product.id})

    assert msg == "Awaiting a human."

    [event] = recent_audit("cf_list_competitors")
    assert event.result_status == "blocked_escalated"
    assert event.result_summary == "escalated"
  end

  test "cf_recent_scoreboard is exempt from the short-circuit", %{product: product} do
    open_mcp_escalation!(product)

    # Should run through to the actual handler. The handler may
    # return ok with empty winners/losers; either way the result
    # must NOT be the escalated envelope.
    result = Server.handle_tool_call("cf_recent_scoreboard", %{"product_id" => product.id})
    refute match?({:error, %{code: "escalated"}}, result)
  end

  test "expired escalation is no longer blocking", %{product: product} do
    event = open_mcp_escalation!(product)

    stale_at = DateTime.add(DateTime.utc_now(), -7200, :second)

    Repo.update_all(
      from(e in Escalations.EscalationEvent, where: e.id == ^event.id),
      set: [inserted_at: stale_at]
    )

    Application.put_env(:content_forge, :escalations, session_window_seconds: 3600)
    on_exit(fn -> Application.delete_env(:content_forge, :escalations) end)

    result = Server.handle_tool_call("cf_list_competitors", %{"product_id" => product.id})
    refute match?({:error, %{code: "escalated"}}, result)
  end

  test "resolved escalation is no longer blocking", %{product: product} do
    event = open_mcp_escalation!(product)
    {:ok, _} = Escalations.mark_resolved(event, "operator")

    result = Server.handle_tool_call("cf_list_competitors", %{"product_id" => product.id})
    refute match?({:error, %{code: "escalated"}}, result)
  end

  test "escalation on a different product does not block this product", %{product: product} do
    {:ok, other} =
      Products.create_product(%{
        name: "Other Esc Product #{System.unique_integer()}",
        voice_profile: "professional"
      })

    open_mcp_escalation!(other)

    result = Server.handle_tool_call("cf_list_competitors", %{"product_id" => product.id})
    refute match?({:error, %{code: "escalated"}}, result)
  end

  defp recent_audit(tool_name) do
    import Ecto.Query

    ToolInvocationEvent
    |> where([e], e.tool_name == ^tool_name)
    |> order_by([e], desc: e.invoked_at)
    |> Repo.all()
  end
end
