defmodule ContentForgeWeb.Live.Dashboard.Sms.NeedsAttentionLive do
  @moduledoc """
  Operator dashboard for SMS conversations that need human attention.

  Two sections:

    * **Escalated** - sessions with a non-nil `escalated_at`. These
      were marked by `ContentForge.Sms.escalate_session/3` (either by
      an operator action or, in the future, by OpenClaw's confidence
      gate). Each row shows the product name, phone number, last
      inbound body, escalation reason, and escalated-at timestamp,
      plus a "Mark resolved" button that calls
      `ContentForge.Sms.resolve_session/1`.
    * **High volume / needs reply** - sessions with >= 10 inbound
      messages in the last 24h and no outbound reply in that same
      window. Excludes already-escalated sessions so a single
      conversation never double-renders.
  """
  use ContentForgeWeb, :live_view

  alias ContentForge.Products
  alias ContentForge.Repo
  alias ContentForge.Sms
  alias ContentForge.Sms.ConversationSession

  @default_high_volume_threshold 10
  @high_volume_window_seconds 86_400

  @impl true
  def mount(_params, _session, socket) do
    {:ok, refresh(socket)}
  end

  @impl true
  def handle_event("resolve", %{"session-id" => id}, socket) do
    case Repo.get(ConversationSession, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Session not found")}

      session ->
        {:ok, _} = Sms.resolve_session(session)

        {:noreply,
         socket
         |> put_flash(:info, "Session resolved - auto-response resumed")
         |> refresh()}
    end
  end

  defp refresh(socket) do
    escalated = Sms.list_escalated_sessions()

    high_volume =
      Sms.list_high_volume_sessions(
        threshold: @default_high_volume_threshold,
        seconds: @high_volume_window_seconds
      )

    ids =
      (escalated ++ high_volume)
      |> Enum.map(& &1.product_id)
      |> Enum.uniq()

    product_map = load_product_map(ids)
    last_inbound_map = build_last_inbound_map(escalated ++ high_volume)

    assign(socket,
      escalated_sessions: escalated,
      high_volume_sessions: high_volume,
      product_map: product_map,
      last_inbound_map: last_inbound_map
    )
  end

  defp load_product_map([]), do: %{}

  defp load_product_map(ids) do
    ids
    |> Enum.map(&Products.get_product/1)
    |> Enum.filter(& &1)
    |> Map.new(fn product -> {product.id, product} end)
  end

  defp build_last_inbound_map(sessions) do
    Map.new(sessions, fn session ->
      {session.id, last_inbound_body(session)}
    end)
  end

  defp last_inbound_body(%ConversationSession{} = session) do
    case Sms.list_events(session.product_id,
           phone_number: session.phone_number,
           direction: "inbound",
           status: "received"
         ) do
      [%{body: body} | _] when is_binary(body) -> body
      _ -> ""
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h1 class="text-2xl font-bold">SMS - Needs Attention</h1>
        <p class="text-base-content/70">
          Conversations awaiting a human response.
        </p>
      </div>

      <div class="card bg-base-200">
        <div class="card-body">
          <h2 class="card-title">Escalated ({length(@escalated_sessions)})</h2>

          <div
            :if={@escalated_sessions == []}
            class="text-center py-8 text-base-content/70"
          >
            No escalated sessions
          </div>

          <div :if={@escalated_sessions != []} class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Product</th>
                  <th>Phone</th>
                  <th>Last inbound</th>
                  <th>Reason</th>
                  <th>Escalated</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={session <- @escalated_sessions}
                  id={"escalated-session-#{session.id}"}
                  data-escalated-session={session.id}
                >
                  <td>{product_name(@product_map, session.product_id)}</td>
                  <td class="font-mono text-xs">{session.phone_number}</td>
                  <td class="max-w-xs truncate">
                    {Map.get(@last_inbound_map, session.id, "")}
                  </td>
                  <td class="max-w-xs truncate">{session.escalation_reason}</td>
                  <td class="text-xs whitespace-nowrap">
                    {format_ts(session.escalated_at)}
                  </td>
                  <td>
                    <button
                      type="button"
                      class="btn btn-sm btn-primary"
                      phx-click="resolve"
                      phx-value-session-id={session.id}
                      aria-label={"Mark session #{session.id} resolved"}
                    >
                      Mark resolved
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <div class="card bg-base-200">
        <div class="card-body">
          <h2 class="card-title">High volume - no reply ({length(@high_volume_sessions)})</h2>
          <p class="text-xs text-base-content/70">
            Sessions with >= 10 inbound messages in the last 24h and no outbound reply.
          </p>

          <div
            :if={@high_volume_sessions == []}
            class="text-center py-8 text-base-content/70"
          >
            No sessions exceed the high-volume threshold right now
          </div>

          <div :if={@high_volume_sessions != []} class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Product</th>
                  <th>Phone</th>
                  <th>Last inbound</th>
                  <th>Last message at</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={session <- @high_volume_sessions}
                  id={"high-volume-session-#{session.id}"}
                  data-high-volume-session={session.id}
                >
                  <td>{product_name(@product_map, session.product_id)}</td>
                  <td class="font-mono text-xs">{session.phone_number}</td>
                  <td class="max-w-xs truncate">
                    {Map.get(@last_inbound_map, session.id, "")}
                  </td>
                  <td class="text-xs whitespace-nowrap">
                    {format_ts(session.last_message_at)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp product_name(map, id) do
    case Map.get(map, id) do
      %{name: name} -> name
      _ -> "(unknown product)"
    end
  end

  defp format_ts(nil), do: ""

  defp format_ts(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
