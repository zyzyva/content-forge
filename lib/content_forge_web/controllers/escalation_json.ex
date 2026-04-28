defmodule ContentForgeWeb.EscalationJSON do
  alias ContentForge.Escalations.EscalationEvent

  def show(%{event: %EscalationEvent{} = event}) do
    %{data: serialize(event)}
  end

  def serialize(%EscalationEvent{} = event) do
    %{
      id: event.id,
      product_id: event.product_id,
      session_id: event.session_id,
      channel: event.channel,
      sender_identity: event.sender_identity,
      reason: event.reason,
      urgency: event.urgency,
      resolved: event.resolved,
      resolved_at: event.resolved_at,
      resolved_by: event.resolved_by,
      holding_reply: event.holding_reply,
      inserted_at: event.inserted_at,
      updated_at: event.updated_at
    }
  end
end
