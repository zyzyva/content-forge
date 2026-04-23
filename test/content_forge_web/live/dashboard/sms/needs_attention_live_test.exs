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
      assert html =~ "No escalated sessions"
      assert html =~ "High volume"
      assert html =~ "No sessions exceed the high-volume threshold"
    end
  end

  describe "escalated section" do
    test "lists escalated sessions with product, phone, reason, and last inbound",
         %{conn: conn} do
      product = create_product!("Johnson remodel")
      session = create_phone_and_session!(product, "+15551110001")
      _ = record_inbound!(product, "+15551110001", "Is there really no backsplash?")
      {:ok, _} = Sms.escalate_session(session, "bot could not answer")

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/sms")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, html}}

      assert html =~ "Johnson remodel"
      assert html =~ "+15551110001"
      assert html =~ "bot could not answer"
      assert html =~ "Is there really no backsplash?"
      assert html =~ ~s|data-escalated-session="#{session.id}"|

      assert render(view) =~ "Mark resolved"
    end

    test "mark-resolved removes the row and flashes success", %{conn: conn} do
      product = create_product!()
      session = create_phone_and_session!(product)
      _ = record_inbound!(product, "+15551112222")
      {:ok, _} = Sms.escalate_session(session, "temporary")

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/sms")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, view, _html}}

      html =
        render_click(view, "resolve", %{"session-id" => session.id})

      refute html =~ ~s|data-escalated-session="#{session.id}"|

      # Context row actually flipped.
      reloaded = ContentForge.Repo.get!(ContentForge.Sms.ConversationSession, session.id)
      assert reloaded.escalated_at == nil
      assert reloaded.auto_response_paused == false
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

    test "does not double-render a session that is already escalated",
         %{conn: conn} do
      product = create_product!()
      session = create_phone_and_session!(product, "+15551110004")

      Enum.each(1..11, fn _ -> record_inbound!(product, "+15551110004") end)
      {:ok, _} = Sms.escalate_session(session, "gotta handle")

      capture_log(fn ->
        result = live(conn, ~p"/dashboard/sms")
        send(self(), {:result, result})
      end)

      assert_received {:result, {:ok, _view, html}}

      assert html =~ ~s|data-escalated-session="#{session.id}"|
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
