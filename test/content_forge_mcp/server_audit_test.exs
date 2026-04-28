defmodule ContentForgeMCP.ServerAuditTest do
  @moduledoc """
  Phase 16.5 dispatch coverage for the MCP surface. Asserts every
  MCP tool call produces a `ToolInvocationEvent` row with channel
  = "mcp" and the right result_status classification.
  """

  use ContentForge.DataCase, async: false

  alias ContentForge.Products
  alias ContentForge.Repo
  alias ContentForge.ToolAudit.ToolInvocationEvent
  alias ContentForgeMCP.Server

  test "successful MCP tool call logs an ok row with channel=mcp" do
    {:ok, _result} = Server.handle_tool_call("cf_create_product", %{"name" => "Audit MCP"})

    [event] = recent_events("cf_create_product")
    assert event.channel == "mcp"
    assert event.result_status == "ok"
    assert is_integer(event.duration_ms)
    assert event.product_id != nil
  end

  test "MCP error envelope is logged as an error row with the code as summary" do
    # cf_add_competitor without name -> validation_failed
    {:error, %{code: code}} = Server.handle_tool_call("cf_add_competitor", %{})

    [event] = recent_events("cf_add_competitor")
    assert event.channel == "mcp"
    assert event.result_status == "error"
    assert event.result_summary == code
  end

  test "unknown MCP tool name logs an error row" do
    Server.handle_tool_call("cf_does_not_exist", %{})

    [event] = recent_events("cf_does_not_exist")
    assert event.channel == "mcp"
    assert event.result_status == "error"
    assert event.result_summary == "not_found"
  end

  test "every registered MCP tool produces an audit row when invoked" do
    # Pre-create one product so tools that need a product_id have something.
    {:ok, product} =
      Products.create_product(%{
        name: "MCP Audit Source #{System.unique_integer()}",
        voice_profile: "professional"
      })

    tools = [
      "cf_create_product",
      "cf_list_products",
      "cf_add_competitor",
      "cf_list_competitors",
      "cf_scrape_competitor",
      "cf_top_posts_for_synthesis",
      "cf_store_intel",
      "cf_get_intel",
      "cf_list_pending_syntheses",
      "cf_import_twitter_sqlite",
      "cf_recent_scoreboard"
    ]

    for tool_name <- tools do
      args =
        case tool_name do
          "cf_create_product" -> %{"name" => "X #{System.unique_integer()}"}
          _ -> %{"product_id" => product.id}
        end

      _ = Server.handle_tool_call(tool_name, args)
      assert [_ | _] = recent_events(tool_name), "Expected audit row for #{tool_name}"
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
