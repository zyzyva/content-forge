defmodule ContentForgeWeb.Live.Dashboard.ToolActivity.LiveTest do
  use ContentForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ContentForge.Products
  alias ContentForge.ToolAudit

  defp seed_events!(product) do
    {:ok, _ok_event} =
      ToolAudit.log_invocation(
        "create_upload_link",
        %{channel: "openclaw_cli", sender_identity: "cli:ops"},
        %{"product" => "Acme"},
        {:ok, %{product_id: product.id, url: "u"}},
        %{duration_ms: 5}
      )

    {:ok, _err_event} =
      ToolAudit.log_invocation(
        "draft_status",
        %{channel: "mcp"},
        %{"product_id" => product.id},
        {:error, :forbidden},
        %{duration_ms: 2, product_id: product.id}
      )

    {:ok, _conf_event} =
      ToolAudit.log_invocation(
        "approve_draft",
        %{channel: "openclaw_sms", sender_identity: "+15551112222"},
        %{},
        {:ok, :confirmation_required, %{echo_phrase: "abc def ghi"}},
        %{product_id: product.id}
      )
  end

  describe "mount + render" do
    setup do
      {:ok, product} =
        Products.create_product(%{
          name: "Tool Activity LV #{System.unique_integer()}",
          voice_profile: "professional"
        })

      seed_events!(product)
      %{product: product}
    end

    test "renders the page header and recent invocations", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/tool-activity")
      assert html =~ "Tool Activity"
      assert html =~ "create_upload_link"
      assert html =~ "draft_status"
      assert html =~ "approve_draft"
    end

    test "status badges render with the right semantic class", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/tool-activity")
      assert html =~ "badge-success"
      assert html =~ "badge-error"
      assert html =~ "badge-warning"
    end

    test "filter by tool narrows the table", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/tool-activity")

      html =
        view
        |> form("form", %{"filters" => %{"tool" => "draft_status"}})
        |> render_change()

      assert table_row_count(html) == 1
      assert html =~ ~s|<td class="font-mono text-xs">draft_status</td>|
    end

    test "filter by channel narrows the table", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/tool-activity")

      html =
        view
        |> form("form", %{"filters" => %{"channel" => "mcp"}})
        |> render_change()

      assert table_row_count(html) == 1
      assert html =~ ~s|<td class="text-xs">mcp</td>|
    end

    test "filter by status narrows the table", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/tool-activity")

      html =
        view
        |> form("form", %{"filters" => %{"status" => "confirmation_required"}})
        |> render_change()

      assert table_row_count(html) == 1
      # The confirmation-required row is the approve_draft seed.
      assert html =~ ~s|<td class="font-mono text-xs">approve_draft</td>|
    end

    test "renders a friendly empty-state when filters match nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/tool-activity")

      # `unknown_tool` is a valid status option but the seeded events
      # never produce it, so this exercises the empty path through a
      # legal select value.
      html =
        view
        |> form("form", %{"filters" => %{"status" => "unknown_tool"}})
        |> render_change()

      assert html =~ "No tool invocations match"
      assert table_row_count(html) == 0
    end
  end

  defp table_row_count(html) do
    html
    |> String.split(~r/<tr id="tool-invocation-/)
    |> length()
    |> Kernel.-(1)
  end
end
