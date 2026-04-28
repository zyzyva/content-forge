defmodule ContentForge.OpenClawToolsAuditTest do
  @moduledoc """
  Phase 16.5 dispatch coverage: every OpenClaw tool dispatch
  produces a `ToolInvocationEvent` row, including unknown-tool
  short-circuits. Pinned generically with a stub tool so adding
  or removing a tool from the registry does not require changing
  this test.
  """

  use ContentForge.DataCase, async: false

  alias ContentForge.OpenClawTools
  alias ContentForge.Repo
  alias ContentForge.ToolAudit.ToolInvocationEvent

  defmodule StubTool do
    @moduledoc false
    def call(_ctx, %{"raise" => true}), do: {:error, :forbidden}
    def call(_ctx, _params), do: {:ok, %{ok: true}}
  end

  setup do
    original = Application.get_env(:content_forge, :extra_open_claw_tools, %{})

    Application.put_env(:content_forge, :extra_open_claw_tools, %{
      "stub_audit_tool" => StubTool
    })

    on_exit(fn ->
      Application.put_env(:content_forge, :extra_open_claw_tools, original)
    end)

    :ok
  end

  test "successful dispatch logs an ok row with the OpenClaw channel namespace" do
    OpenClawTools.dispatch(
      "stub_audit_tool",
      %{channel: "cli", sender_identity: "cli:ops"},
      %{}
    )

    [event] = recent_events("stub_audit_tool")
    assert event.tool_name == "stub_audit_tool"
    assert event.channel == "openclaw_cli"
    assert event.result_status == "ok"
    assert event.sender_identity == "cli:ops"
    assert is_integer(event.duration_ms)
  end

  test "error dispatch logs an error row with the classified summary" do
    OpenClawTools.dispatch(
      "stub_audit_tool",
      %{channel: "cli"},
      %{"raise" => true}
    )

    [event] = recent_events("stub_audit_tool")
    assert event.result_status == "error"
    assert event.result_summary == "forbidden"
  end

  test "unknown tool dispatch still logs a row with unknown_tool status" do
    OpenClawTools.dispatch("does_not_exist", %{channel: "sms"}, %{})

    [event] = recent_events("does_not_exist")
    assert event.tool_name == "does_not_exist"
    assert event.channel == "openclaw_sms"
    assert event.result_status == "unknown_tool"
    assert event.result_summary == "unknown_tool"
  end

  test "phone-number sender_identity is hashed; non-phone identity is preserved" do
    OpenClawTools.dispatch(
      "stub_audit_tool",
      %{channel: "sms", sender_identity: "+15551234567"},
      %{}
    )

    OpenClawTools.dispatch(
      "stub_audit_tool",
      %{channel: "cli", sender_identity: "cli:ops"},
      %{}
    )

    events = recent_events("stub_audit_tool")
    assert Enum.any?(events, &(&1.sender_identity == "cli:ops"))

    assert Enum.any?(events, fn e ->
             is_binary(e.sender_identity) and String.starts_with?(e.sender_identity, "sha256:")
           end)
  end

  test "PII keys in params are redacted in the persisted row" do
    OpenClawTools.dispatch(
      "stub_audit_tool",
      %{channel: "sms"},
      %{"phone_number" => "+15551234567", "filename" => "x.txt"}
    )

    [event] = recent_events("stub_audit_tool")
    assert event.params["filename"] == "x.txt"
    assert String.starts_with?(event.params["phone_number"], "sha256:")
    refute event.params["phone_number"] =~ "5551234567"
  end

  test "every registered tool name has an audit row when invoked through dispatch" do
    # Real tools generally fail without a configured product, but
    # the audit row must land regardless. We invoke each registered
    # tool with empty params + ctx and just assert a row exists.
    for tool_name <- OpenClawTools.registered_tools() do
      _ = OpenClawTools.dispatch(tool_name, %{channel: "cli"}, %{})
      assert [_ | _] = recent_events(tool_name)
    end
  end

  defp recent_events(tool_name) do
    import Ecto.Query

    ToolInvocationEvent
    |> where([e], e.tool_name == ^tool_name)
    |> order_by([e], desc: e.invoked_at)
    |> Repo.all()
  end
end
