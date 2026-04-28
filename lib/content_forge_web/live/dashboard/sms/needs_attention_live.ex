defmodule ContentForgeWeb.Live.Dashboard.Sms.NeedsAttentionLive do
  @moduledoc """
  Operator dashboard for conversations that need human attention.

  Phase 16.6 made this page channel-agnostic: the **Escalated**
  section now sources from `ContentForge.Escalations.list_open/1`
  so it lists open escalations regardless of channel (SMS,
  OpenClaw CLI, OpenClaw SMS, MCP). The 14.5 SMS-specific
  resolve behavior (clearing `escalated_at` + unpausing
  auto-response) is preserved: when the operator resolves a
  `channel: "sms"` row, the LiveView marks the
  `EscalationEvent` resolved AND unpauses the underlying
  `ConversationSession`.

  Two sections:

    * **Escalated** - open `EscalationEvent` rows across every
      channel. Each row shows the product, channel, sender
      identity (hashed for phone-shaped senders), reason
      snippet, and escalated-at timestamp, plus a "Mark
      resolved" button.
    * **High volume / needs reply** - SMS-only. Sessions with
      >= 10 inbound messages in the last 24h and no outbound
      reply. Unchanged from 14.5.
  """
  use ContentForgeWeb, :live_view

  alias ContentForge.Escalations
  alias ContentForge.Escalations.EscalationEvent
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
  def handle_event("resolve", %{"escalation-id" => id}, socket) do
    case Escalations.get(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Escalation not found")}

      %EscalationEvent{} = event ->
        {:ok, resolved} = Escalations.mark_resolved(event, "dashboard-operator")
        _ = maybe_resume_sms_session(resolved)

        {:noreply,
         socket
         |> put_flash(:info, "Escalation resolved")
         |> refresh()}
    end
  end

  defp maybe_resume_sms_session(%EscalationEvent{channel: "sms", session_id: session_id}) do
    case Repo.get(ConversationSession, session_id) do
      nil -> :ok
      %ConversationSession{} = session -> Sms.resolve_session(session)
    end
  end

  defp maybe_resume_sms_session(_), do: :ok

  defp refresh(socket) do
    escalations = Escalations.list_open([])

    high_volume =
      Sms.list_high_volume_sessions(
        threshold: @default_high_volume_threshold,
        seconds: @high_volume_window_seconds
      )

    product_ids =
      (Enum.map(escalations, & &1.product_id) ++ Enum.map(high_volume, & &1.product_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    product_map = load_product_map(product_ids)
    last_inbound_map = build_last_inbound_map(high_volume)

    assign(socket,
      escalations: escalations,
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
    <main id="main-content" aria-labelledby="page-title" class="space-y-6">
      <header>
        <h1 id="page-title" class="text-2xl font-bold">Needs Attention</h1>
        <p class="text-base-content/70">
          Open escalations across every channel, plus the SMS high-volume queue.
        </p>
      </header>

      <section aria-labelledby="escalated-heading" class="card bg-base-200">
        <div class="card-body">
          <h2 id="escalated-heading" class="card-title">
            Escalated ({length(@escalations)})
          </h2>

          <p
            :if={@escalations == []}
            class="text-center py-8 text-base-content/70"
            role="status"
          >
            No open escalations
          </p>

          <div :if={@escalations != []} class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th scope="col">Product</th>
                  <th scope="col">Channel</th>
                  <th scope="col">Sender</th>
                  <th scope="col">Reason</th>
                  <th scope="col">Urgency</th>
                  <th scope="col">Escalated</th>
                  <th scope="col"><span class="sr-only">Actions</span></th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={event <- @escalations}
                  id={"escalation-#{event.id}"}
                  data-escalation-id={event.id}
                >
                  <td>{product_name(@product_map, event.product_id)}</td>
                  <td class="text-xs">{event.channel}</td>
                  <td class="font-mono text-xs max-w-xs truncate">
                    {event.sender_identity || "-"}
                  </td>
                  <td class="max-w-xs truncate">{event.reason}</td>
                  <td>
                    <span class={urgency_class(event.urgency)}>{event.urgency}</span>
                  </td>
                  <td class="text-xs whitespace-nowrap">{format_ts(event.inserted_at)}</td>
                  <td>
                    <button
                      type="button"
                      class="btn btn-sm btn-primary"
                      phx-click="resolve"
                      phx-value-escalation-id={event.id}
                      aria-label={
                        "Mark escalation on " <>
                          product_name(@product_map, event.product_id) <> " resolved"
                      }
                    >
                      Mark resolved
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>

      <section aria-labelledby="high-volume-heading" class="card bg-base-200">
        <div class="card-body">
          <h2 id="high-volume-heading" class="card-title">
            High volume - no reply ({length(@high_volume_sessions)})
          </h2>
          <p class="text-xs text-base-content/70">
            Sessions with >= 10 inbound messages in the last 24h and no outbound reply.
          </p>

          <p
            :if={@high_volume_sessions == []}
            class="text-center py-8 text-base-content/70"
            role="status"
          >
            No sessions exceed the high-volume threshold right now
          </p>

          <div :if={@high_volume_sessions != []} class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th scope="col">Product</th>
                  <th scope="col">Phone</th>
                  <th scope="col">Last inbound</th>
                  <th scope="col">Last message at</th>
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
      </section>
    </main>
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

  defp urgency_class("high"), do: "badge badge-error"
  defp urgency_class("normal"), do: "badge badge-warning"
  defp urgency_class("low"), do: "badge badge-ghost"
  defp urgency_class(_), do: "badge"
end
