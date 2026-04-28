defmodule ContentForgeWeb.Live.Dashboard.ToolActivity.Live do
  @moduledoc """
  Phase 16.5 unified tool-invocation dashboard.

  Lists the most recent N invocations across all products. Filter
  controls narrow by tool name, channel, or result_status; the
  list refreshes on a 30-second timer plus on every form submit.

  Mobile-first markup, semantic HTML, ARIA-labeled filter
  controls, keyboard nav. Mirrors the
  `GET /api/v1/products/:id/tool-activity` REST surface for
  external parity.
  """

  use ContentForgeWeb, :live_view

  alias ContentForge.OpenClawTools
  alias ContentForge.Products
  alias ContentForge.ToolAudit
  alias ContentForge.ToolAudit.ToolInvocationEvent

  @refresh_ms 30_000
  @default_limit 100
  @channels ~w(openclaw_sms openclaw_cli openclaw_unknown mcp)
  @mcp_tools ~w(
    cf_create_product
    cf_list_products
    cf_add_competitor
    cf_list_competitors
    cf_scrape_competitor
    cf_top_posts_for_synthesis
    cf_store_intel
    cf_get_intel
    cf_list_pending_syntheses
    cf_import_twitter_sqlite
    cf_recent_scoreboard
  )

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_refresh()

    {:ok,
     socket
     |> assign(:filters, %{tool: "", channel: "", status: ""})
     |> assign(:tool_options, tool_options())
     |> assign(:channel_options, @channels)
     |> assign(:status_options, ToolInvocationEvent.result_statuses())
     |> refresh()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event("filter", %{"filters" => attrs}, socket) do
    filters = %{
      tool: Map.get(attrs, "tool", ""),
      channel: Map.get(attrs, "channel", ""),
      status: Map.get(attrs, "status", "")
    }

    {:noreply, socket |> assign(:filters, filters) |> refresh()}
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_ms)

  defp refresh(socket) do
    filters = socket.assigns[:filters] || %{tool: "", channel: "", status: ""}

    events =
      ToolAudit.list_recent(
        tool: filters[:tool],
        channel: filters[:channel],
        status: filters[:status],
        limit: @default_limit
      )

    product_map = product_map_for(events)

    socket
    |> assign(:events, events)
    |> assign(:product_map, product_map)
  end

  defp product_map_for([]), do: %{}

  defp product_map_for(events) do
    ids =
      events
      |> Enum.map(& &1.product_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Products.list_products()
    |> Enum.filter(&(&1.id in ids))
    |> Map.new(&{&1.id, &1.name})
  end

  defp tool_options do
    (OpenClawTools.registered_tools() ++ @mcp_tools)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp product_label(_map, nil), do: "-"
  defp product_label(map, id), do: Map.get(map, id, "(deleted product)")

  defp status_class("ok"), do: "badge badge-success"
  defp status_class("error"), do: "badge badge-error"
  defp status_class("confirmation_required"), do: "badge badge-warning"
  defp status_class("unknown_tool"), do: "badge badge-ghost"
  defp status_class(_), do: "badge"

  defp format_ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_ts(_), do: ""

  defp format_duration(nil), do: ""
  defp format_duration(ms) when is_integer(ms), do: "#{ms} ms"

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main-content" aria-labelledby="page-title" class="space-y-6">
      <header>
        <h1 id="page-title" class="text-2xl font-bold">Tool Activity</h1>
        <p class="text-base-content/70">
          Unified audit of every tool call across the OpenClaw and MCP surfaces. Latest {length(
            @events
          )} invocations, refreshing every 30 seconds.
        </p>
      </header>

      <section aria-labelledby="filters-heading" class="card bg-base-200">
        <div class="card-body">
          <h2 id="filters-heading" class="card-title text-base">Filters</h2>

          <form
            phx-change="filter"
            phx-submit="filter"
            class="grid grid-cols-1 sm:grid-cols-3 gap-3"
            aria-label="Filter tool activity"
          >
            <label class="form-control w-full">
              <span class="label-text">Tool</span>
              <select
                name="filters[tool]"
                class="select select-bordered"
                aria-label="Filter by tool name"
              >
                <option value="" selected={@filters.tool == ""}>All tools</option>
                <%= for tool <- @tool_options do %>
                  <option value={tool} selected={@filters.tool == tool}>{tool}</option>
                <% end %>
              </select>
            </label>

            <label class="form-control w-full">
              <span class="label-text">Channel</span>
              <select
                name="filters[channel]"
                class="select select-bordered"
                aria-label="Filter by channel"
              >
                <option value="" selected={@filters.channel == ""}>All channels</option>
                <%= for ch <- @channel_options do %>
                  <option value={ch} selected={@filters.channel == ch}>{ch}</option>
                <% end %>
              </select>
            </label>

            <label class="form-control w-full">
              <span class="label-text">Status</span>
              <select
                name="filters[status]"
                class="select select-bordered"
                aria-label="Filter by result status"
              >
                <option value="" selected={@filters.status == ""}>All statuses</option>
                <%= for st <- @status_options do %>
                  <option value={st} selected={@filters.status == st}>{st}</option>
                <% end %>
              </select>
            </label>
          </form>
        </div>
      </section>

      <section aria-labelledby="events-heading" class="card bg-base-200">
        <div class="card-body">
          <h2 id="events-heading" class="card-title">Recent invocations</h2>

          <p
            :if={@events == []}
            class="text-center py-8 text-base-content/70"
            role="status"
          >
            No tool invocations match the current filters.
          </p>

          <div :if={@events != []} class="overflow-x-auto">
            <table class="table table-sm">
              <caption class="sr-only">
                Most recent tool invocations across all channels
              </caption>
              <thead>
                <tr>
                  <th scope="col">Time</th>
                  <th scope="col">Tool</th>
                  <th scope="col">Channel</th>
                  <th scope="col">Sender</th>
                  <th scope="col">Product</th>
                  <th scope="col">Status</th>
                  <th scope="col">Summary</th>
                  <th scope="col">Duration</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={event <- @events} id={"tool-invocation-#{event.id}"}>
                  <td class="text-xs whitespace-nowrap">{format_ts(event.invoked_at)}</td>
                  <td class="font-mono text-xs">{event.tool_name}</td>
                  <td class="text-xs">{event.channel}</td>
                  <td class="font-mono text-xs max-w-xs truncate">
                    {event.sender_identity || "-"}
                  </td>
                  <td>{product_label(@product_map, event.product_id)}</td>
                  <td>
                    <span class={status_class(event.result_status)}>
                      {event.result_status}
                    </span>
                  </td>
                  <td class="text-xs max-w-xs truncate">{event.result_summary || ""}</td>
                  <td class="text-xs whitespace-nowrap">{format_duration(event.duration_ms)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>
    </main>
    """
  end
end
