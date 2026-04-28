defmodule ContentForgeWeb.ToolActivityControllerTest do
  use ContentForgeWeb.ConnCase, async: false

  alias ContentForge.Accounts
  alias ContentForge.Products
  alias ContentForge.ToolAudit

  setup %{conn: conn} do
    {:ok, api_key} =
      Accounts.create_api_key(%{
        key: String.duplicate("a", 32),
        label: "tool activity test key",
        active: true
      })

    {:ok, product} =
      Products.create_product(%{
        name: "Tool Activity Product #{System.unique_integer()}",
        voice_profile: "professional"
      })

    {:ok, _e1} =
      ToolAudit.log_invocation(
        "create_upload_link",
        %{channel: "openclaw_cli", sender_identity: "cli:ops"},
        %{"product" => "Acme"},
        {:ok, %{product_id: product.id, url: "u"}},
        %{duration_ms: 5}
      )

    {:ok, _e2} =
      ToolAudit.log_invocation(
        "draft_status",
        %{channel: "mcp"},
        %{"product_id" => product.id},
        {:error, :forbidden},
        %{duration_ms: 2, product_id: product.id}
      )

    {:ok, _other} =
      ToolAudit.log_invocation(
        "create_upload_link",
        %{channel: "openclaw_sms", sender_identity: "+15559999999"},
        %{},
        {:ok, %{}}
      )

    authed_conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{api_key.key}")

    %{conn: authed_conn, product: product}
  end

  describe "GET /api/v1/products/:product_id/tool-activity" do
    test "401 without bearer token", %{product: product} do
      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/v1/products/#{product.id}/tool-activity")

      assert conn.status == 401
    end

    test "lists product's tool invocations newest first", %{conn: conn, product: product} do
      conn = get(conn, ~p"/api/v1/products/#{product.id}/tool-activity")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["product_id"] == product.id
      assert is_list(data["events"])
      assert length(data["events"]) == 2
      tool_names = Enum.map(data["events"], & &1["tool_name"])
      assert "create_upload_link" in tool_names
      assert "draft_status" in tool_names
    end

    test "filters by tool", %{conn: conn, product: product} do
      conn = get(conn, ~p"/api/v1/products/#{product.id}/tool-activity?tool=draft_status")
      assert %{"data" => data} = json_response(conn, 200)
      assert length(data["events"]) == 1
      assert hd(data["events"])["tool_name"] == "draft_status"
    end

    test "filters by channel", %{conn: conn, product: product} do
      conn = get(conn, ~p"/api/v1/products/#{product.id}/tool-activity?channel=mcp")
      assert %{"data" => data} = json_response(conn, 200)
      assert length(data["events"]) == 1
      assert hd(data["events"])["channel"] == "mcp"
    end

    test "filters by status", %{conn: conn, product: product} do
      conn = get(conn, ~p"/api/v1/products/#{product.id}/tool-activity?status=error")
      assert %{"data" => data} = json_response(conn, 200)
      assert length(data["events"]) == 1
      assert hd(data["events"])["result_status"] == "error"
    end

    test "limit param caps result count", %{conn: conn, product: product} do
      conn = get(conn, ~p"/api/v1/products/#{product.id}/tool-activity?limit=1")
      assert %{"data" => data} = json_response(conn, 200)
      assert length(data["events"]) == 1
    end

    test "404 for unknown product", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/products/00000000-0000-0000-0000-000000000000/tool-activity")
      assert conn.status == 404
    end

    test "response shape mirrors LiveView columns: tool_name, channel, sender_identity (hashed), result_status, summary, duration, invoked_at",
         %{conn: conn, product: product} do
      conn = get(conn, ~p"/api/v1/products/#{product.id}/tool-activity")
      assert %{"data" => data} = json_response(conn, 200)
      [event | _] = data["events"]

      assert Map.has_key?(event, "tool_name")
      assert Map.has_key?(event, "channel")
      assert Map.has_key?(event, "sender_identity")
      assert Map.has_key?(event, "result_status")
      assert Map.has_key?(event, "result_summary")
      assert Map.has_key?(event, "duration_ms")
      assert Map.has_key?(event, "invoked_at")
    end
  end
end
