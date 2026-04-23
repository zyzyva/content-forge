defmodule ContentForgeWeb.Live.Dashboard.Providers.StatusLive do
  @moduledoc """
  Read-only status panel for every external integration the app
  depends on (Media Forge, Anthropic, Gemini, OpenClaw, Apify,
  Twilio).

  Each row shows a colored badge (:available / :configured /
  :unavailable / :degraded), a last-success-at timestamp, a
  last-error-at timestamp (when degraded), and a short note (usually
  the env-var name to set).

  The LiveView reads exclusively from application config and the audit
  tables. It never issues a synthetic call to the upstream - loading
  this page cannot cause a Twilio or Anthropic roundtrip.
  """
  use ContentForgeWeb, :live_view

  alias ContentForge.Providers

  @impl true
  def mount(_params, _session, socket) do
    {:ok, refresh(socket)}
  end

  defp refresh(socket) do
    rows = Providers.list_provider_statuses()
    summary = rows |> to_summary()
    assign(socket, rows: rows, summary: summary)
  end

  defp to_summary(rows) do
    Enum.reduce(rows, %{available: 0, configured: 0, unavailable: 0, degraded: 0}, fn row, acc ->
      Map.update(acc, row.status, 1, &(&1 + 1))
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h1 class="text-2xl font-bold">Provider Status</h1>
        <p class="text-base-content/70">
          Live read of app config + audit tables. No synthetic probes.
        </p>
      </div>

      <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
        <div class="stat bg-base-200">
          <div class="stat-title">Available</div>
          <div class="stat-value text-success text-2xl" data-summary-available>
            {@summary.available}
          </div>
        </div>
        <div class="stat bg-base-200">
          <div class="stat-title">Configured</div>
          <div class="stat-value text-info text-2xl" data-summary-configured>
            {@summary.configured}
          </div>
        </div>
        <div class="stat bg-base-200">
          <div class="stat-title">Unavailable</div>
          <div class="stat-value text-error text-2xl" data-summary-unavailable>
            {@summary.unavailable}
          </div>
        </div>
        <div class="stat bg-base-200">
          <div class="stat-title">Degraded</div>
          <div class="stat-value text-warning text-2xl" data-summary-degraded>
            {@summary.degraded}
          </div>
        </div>
      </div>

      <div class="card bg-base-200">
        <div class="card-body">
          <h2 class="card-title">Integrations</h2>

          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Provider</th>
                  <th>Status</th>
                  <th>Last success</th>
                  <th>Last error</th>
                  <th>Note</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={row <- @rows}
                  id={"provider-row-#{row.id}"}
                  data-provider-id={row.id}
                  data-provider-status={row.status}
                >
                  <td class="font-semibold">{row.name}</td>
                  <td><span class={badge_classes(row.status)}>{badge_text(row.status)}</span></td>
                  <td class="text-xs whitespace-nowrap">{format_ts(row.last_success_at)}</td>
                  <td class="text-xs whitespace-nowrap">{format_ts(row.last_error_at)}</td>
                  <td class="text-xs text-base-content/70">{row.note}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp badge_classes(:available), do: "badge badge-success"
  defp badge_classes(:configured), do: "badge badge-info"
  defp badge_classes(:unavailable), do: "badge badge-error"
  defp badge_classes(:degraded), do: "badge badge-warning"

  defp badge_text(:available), do: "Available"
  defp badge_text(:configured), do: "Configured"
  defp badge_text(:unavailable), do: "Unavailable"
  defp badge_text(:degraded), do: "Degraded"

  defp format_ts(nil), do: "-"

  defp format_ts(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
