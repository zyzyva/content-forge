defmodule ContentForge.OpenClawTools.EscalateToHuman do
  @moduledoc """
  OpenClaw tool: flags a session for human attention.

  The agent should call this when it cannot confidently handle
  the request, when the user asks to speak to a human, when the
  conversation involves pricing or contract questions, when there
  is a complaint, or when the user expresses frustration. It is
  intentionally not gated for routine inability-to-help; only call
  when escalation is genuinely warranted.

  Authorization: requires `:viewer` role (anyone authenticated can
  ask for help; this is not destructive).

  Params:

    * `"reason"` (required) - free-form summary, 1..2000 chars,
      explaining why the agent is escalating. Operators read this
      verbatim on the dashboard, so it should describe the user's
      situation rather than the agent's internal state.
    * `"urgency"` (optional) - one of `"low"`, `"normal"`, `"high"`,
      default `"normal"`.
    * `"product"` (optional) - product name OR id, resolved via
      `ProductResolver`. SMS callers can omit when a registered
      phone supplies the product.

  Returns `%{event_id, escalated_at, channel, holding_reply,
  urgency}`. The Node plugin renderer reads `holding_reply` back
  to the user verbatim.

  Errors: `:forbidden`, `:missing_product_context`,
  `:product_not_found`, `:ambiguous_product`, plus changeset
  errors for invalid reason / urgency.
  """

  alias ContentForge.Escalations
  alias ContentForge.OpenClawTools.Authorization
  alias ContentForge.OpenClawTools.ProductResolver

  @default_urgency "normal"

  @spec call(map(), map()) :: {:ok, map()} | {:error, term()}
  def call(ctx, params) when is_map(params) do
    with {:ok, reason} <- fetch_reason(params),
         {:ok, urgency} <- fetch_urgency(params),
         {:ok, product} <- ProductResolver.resolve(ctx, params),
         :ok <- Authorization.require(Map.put(ctx, :product, product), :viewer),
         {:ok, event} <- escalate(ctx, product, reason, urgency) do
      {:ok,
       %{
         event_id: event.id,
         product_id: product.id,
         product_name: product.name,
         channel: event.channel,
         escalated_at: DateTime.to_iso8601(event.inserted_at),
         holding_reply: event.holding_reply,
         urgency: event.urgency
       }}
    end
  end

  defp fetch_reason(%{"reason" => reason}) when is_binary(reason) and reason != "" do
    if String.length(reason) > 2_000,
      do: {:error, :reason_too_long},
      else: {:ok, reason}
  end

  defp fetch_reason(_), do: {:error, :reason_required}

  defp fetch_urgency(%{"urgency" => u}) when u in ["low", "normal", "high"], do: {:ok, u}
  defp fetch_urgency(%{"urgency" => _}), do: {:error, :invalid_urgency}
  defp fetch_urgency(_), do: {:ok, @default_urgency}

  defp escalate(ctx, product, reason, urgency) do
    Escalations.create_or_update_open(%{
      product_id: product.id,
      session_id: session_id_for(ctx),
      channel: namespaced_channel(ctx),
      sender_identity: Map.get(ctx, :sender_identity),
      reason: reason,
      urgency: urgency,
      holding_reply: holding_reply()
    })
  end

  defp session_id_for(ctx) do
    case Map.get(ctx, :session_id) do
      sid when is_binary(sid) and sid != "" -> sid
      _ -> "openclaw-#{Map.get(ctx, :channel) || "unknown"}"
    end
  end

  defp namespaced_channel(ctx) do
    raw = Map.get(ctx, :channel)

    cond do
      raw in [nil, ""] -> "openclaw_unknown"
      is_binary(raw) -> "openclaw_#{raw}"
    end
  end

  defp holding_reply do
    Application.get_env(:content_forge, :escalations, [])
    |> Keyword.get(:holding_reply, default_holding_reply())
  end

  defp default_holding_reply do
    "Thanks - I have flagged this for the team and someone will follow up shortly. " <>
      "You can keep messaging here in the meantime."
  end
end
