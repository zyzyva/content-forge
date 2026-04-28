defmodule ContentForgeWeb.Live.Dashboard.Sms.NeedsAttentionLiveTest do
  use ContentForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog

  alias ContentForge.Products
  alias ContentForge.Sms

  defp create_product!(name \\ "Attention Product") do
    {:ok, product} = Products.create_product(%{name: name, voice_profile: "professional"})
    product
  end

  defp create_phone_and_session!(product, phone_number \\ "+15551112222") do
    {:ok, _phone} =
      Sms.create_phone(%{
        product_id: product.id,
        phone_number: phone_number,
        role: "owner"
      })

    {:ok, session} = Sms.get_or_start_session(product.id, phone_number)
    session
  end

  defp record_inbound!(product, phone_number, body \\ "help") do
    {:ok, event} =
      Sms.record_event(%{
        product_id: product.id,
        phone_number: phone_number,
        direction: "inbound",
        status: "received",
        body: body
      })

    event
  end

  describe "mount" do
    test "renders both sections with empty states", %{conn: conn} do
      capture_log(fn ->
        result = live(conn, ~p"/dashboard/sms")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, _view, html}}

      assert html =~ "Needs Attention"
      assert html =~ "Escalated"
      assert html =~ "No open escalations"
      assert html =~ "High volume"
      assert html =~ "No sessions exceed the high-volume threshold"
    end
  end

  describe "escalated section (Phase 16.6 channel-agnostic)" do
    test "lists open escalations with product, channel, hashed sender, reason, urgency",
         %{conn: conn} do
      product = create_product!("Johnson remodel")
      session = create_phone_and_session!(product, "+15551110001")
      {:ok, _} = Sms.escalate_session(session, "bot could not answer")

      [escalation] = ContentForge.Escalations.list_open([])

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/sms")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, html}}

      assert html =~ "Johnson remodel"
      # Channel column shows generic "sms"
      assert html =~ ~s|<td class="text-xs">sms</td>|
      # Phone-shaped sender is hashed before render.
      assert html =~ "sha256:"
      refute html =~ "+15551110001"
      assert html =~ "bot could not answer"
      assert html =~ ~s|data-escalation-id="#{escalation.id}"|
      assert render(view) =~ "Mark resolved"
    end

    test "mark-resolved closes the EscalationEvent and unpauses the SMS session", %{
      conn: conn
    } do
      product = create_product!()
      session = create_phone_and_session!(product)
      {:ok, _} = Sms.escalate_session(session, "temporary")

      [escalation] = ContentForge.Escalations.list_open([])

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/sms")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}

      html =
        render_click(view, "resolve", %{"escalation-id" => escalation.id})

      refute html =~ ~s|data-escalation-id="#{escalation.id}"|

      reloaded_escalation = ContentForge.Escalations.get(escalation.id)
      assert reloaded_escalation.resolved == true

      reloaded_session =
        ContentForge.Repo.get!(ContentForge.Sms.ConversationSession, session.id)

      assert reloaded_session.escalated_at == nil
      assert reloaded_session.auto_response_paused == false
    end

    test "lists openclaw-channel escalations alongside SMS escalations", %{conn: conn} do
      product = create_product!("Cross channel")

      {:ok, _cli} =
        ContentForge.Escalations.create_or_update_open(%{
          product_id: product.id,
          session_id: "cli-session-77",
          channel: "openclaw_cli",
          reason: "agent ambiguity",
          holding_reply: "hold"
        })

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/sms")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, _view, html}}
      assert html =~ "openclaw_cli"
      assert html =~ "agent ambiguity"
    end
  end

  describe "high-volume section" do
    test "lists sessions with >= 10 inbound in 24h and no outbound",
         %{conn: conn} do
      product = create_product!("Quiet phones")
      session = create_phone_and_session!(product, "+15551110002")

      Enum.each(1..11, fn i ->
        record_inbound!(product, "+15551110002", "ping ##{i}")
      end)

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/sms")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, _view, html}}

      assert html =~ ~s|data-high-volume-session="#{session.id}"|
      assert html =~ "Quiet phones"
    end

    test "does not list sessions that already have an outbound reply",
         %{conn: conn} do
      product = create_product!()
      session = create_phone_and_session!(product, "+15551110003")

      Enum.each(1..11, fn _ -> record_inbound!(product, "+15551110003") end)

      {:ok, _} =
        Sms.record_event(%{
          product_id: product.id,
          phone_number: "+15551110003",
          direction: "outbound",
          status: "sent",
          body: "hi"
        })

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/sms")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, _view, html}}

      refute html =~ ~s|data-high-volume-session="#{session.id}"|
    end

    test "an escalated session shows up only in the escalated section, not in high-volume",
         %{conn: conn} do
      product = create_product!()
      session = create_phone_and_session!(product, "+15551110004")

      Enum.each(1..11, fn _ -> record_inbound!(product, "+15551110004") end)
      {:ok, _} = Sms.escalate_session(session, "gotta handle")

      [escalation] = ContentForge.Escalations.list_open([])

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/sms")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, _view, html}}

      assert html =~ ~s|data-escalation-id="#{escalation.id}"|
      refute html =~ ~s|data-high-volume-session="#{session.id}"|
    end
  end

  describe "dashboard hub" do
    test "SMS card links to /dashboard/sms", %{conn: conn} do
      capture_log(fn ->
        result = live(conn, ~p"/dashboard")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, _view, html}}
      assert html =~ "SMS"
      assert html =~ ~s|href="/dashboard/sms"|
    end
  end
end
