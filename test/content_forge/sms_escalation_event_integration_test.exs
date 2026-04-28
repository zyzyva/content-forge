defmodule ContentForge.SmsEscalationEventIntegrationTest do
  @moduledoc """
  Phase 16.6 SMS path integration: `Sms.escalate_session/3`
  preserves its 14.5 behavior (paused auto-response, SmsEvent
  audit row) and additionally writes a generic
  `EscalationEvent` so the cross-channel dispatcher hook fires
  on SMS-originated escalations.
  """

  use ContentForge.DataCase, async: false

  alias ContentForge.Escalations
  alias ContentForge.Escalations.EscalationEvent
  alias ContentForge.Products
  alias ContentForge.Sms

  setup do
    {:ok, product} =
      Products.create_product(%{
        name: "Sms Esc Integration #{System.unique_integer()}",
        voice_profile: "professional"
      })

    {:ok, _} =
      Sms.create_phone(%{
        product_id: product.id,
        phone_number: "+15558881111",
        role: "submitter",
        active: true
      })

    {:ok, session} = Sms.get_or_start_session(product.id, "+15558881111")
    %{product: product, session: session}
  end

  test "escalate_session writes an EscalationEvent (channel=sms) keyed on the session id", %{
    product: product,
    session: session
  } do
    {:ok, _} = Sms.escalate_session(session, "user is asking about pricing")

    event = Repo.get_by(EscalationEvent, product_id: product.id, session_id: session.id)
    assert event != nil
    assert event.channel == "sms"
    assert event.reason =~ "pricing"
    assert event.resolved == false
    # phone-shaped sender_identity is hashed at write time
    assert String.starts_with?(event.sender_identity, "sha256:")
  end

  test "the 14.5 SMS path is preserved (escalated_at set + auto-response paused)", %{
    session: session
  } do
    {:ok, updated} = Sms.escalate_session(session, "anything")
    assert updated.escalated_at != nil
    assert updated.auto_response_paused == true
  end

  test "re-escalating the same session updates the existing EscalationEvent", %{
    product: product,
    session: session
  } do
    {:ok, _} = Sms.escalate_session(session, "first reason")
    [first] = Escalations.list_open_for_product(product.id, [])

    {:ok, _} = Sms.escalate_session(session, "now actually upset")
    open_rows = Escalations.list_open_for_product(product.id, [])

    assert length(open_rows) == 1
    assert hd(open_rows).id == first.id
    assert hd(open_rows).reason == "now actually upset"
  end
end
