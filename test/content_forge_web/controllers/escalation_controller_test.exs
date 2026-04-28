defmodule ContentForgeWeb.EscalationControllerTest do
  use ContentForgeWeb.ConnCase, async: false

  alias ContentForge.Accounts
  alias ContentForge.Escalations
  alias ContentForge.Escalations.EscalationEvent
  alias ContentForge.Products
  alias ContentForge.Repo
  alias ContentForge.Sms

  setup %{conn: conn} do
    {:ok, api_key} =
      Accounts.create_api_key(%{
        key: String.duplicate("e", 32),
        label: "ops dashboard",
        active: true
      })

    {:ok, product} =
      Products.create_product(%{
        name: "Resolve Endpoint Product #{System.unique_integer()}",
        voice_profile: "professional"
      })

    authed_conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{api_key.key}")

    %{conn: authed_conn, product: product}
  end

  describe "POST /api/v1/escalations/:id/resolve" do
    test "401 without bearer token", %{product: product} do
      {:ok, event} =
        Escalations.create_or_update_open(%{
          product_id: product.id,
          session_id: "x",
          channel: "openclaw_cli",
          reason: "needs human",
          holding_reply: "hold"
        })

      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("accept", "application/json")
        |> post(~p"/api/v1/escalations/#{event.id}/resolve", %{})

      assert conn.status == 401
    end

    test "marks an open escalation resolved and returns the updated row", %{
      conn: conn,
      product: product
    } do
      {:ok, event} =
        Escalations.create_or_update_open(%{
          product_id: product.id,
          session_id: "ops-1",
          channel: "openclaw_cli",
          reason: "needs human",
          holding_reply: "hold"
        })

      conn = post(conn, ~p"/api/v1/escalations/#{event.id}/resolve", %{})
      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == event.id
      assert data["resolved"] == true
      assert data["resolved_at"]
      assert data["resolved_by"] == "ops dashboard"
    end

    test "honors explicit resolved_by from the body", %{conn: conn, product: product} do
      {:ok, event} =
        Escalations.create_or_update_open(%{
          product_id: product.id,
          session_id: "ops-2",
          channel: "openclaw_cli",
          reason: "needs human",
          holding_reply: "hold"
        })

      conn =
        post(conn, ~p"/api/v1/escalations/#{event.id}/resolve", %{
          "resolved_by" => "alice@example.com"
        })

      assert %{"data" => data} = json_response(conn, 200)
      assert data["resolved_by"] == "alice@example.com"
    end

    test "404 for unknown id", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/escalations/00000000-0000-0000-0000-000000000000/resolve", %{})

      assert conn.status == 404
    end

    test "resolving an SMS-channel escalation also unpauses the SMS session", %{
      conn: conn,
      product: product
    } do
      {:ok, _phone} =
        Sms.create_phone(%{
          product_id: product.id,
          phone_number: "+15557770001",
          role: "submitter"
        })

      {:ok, session} = Sms.get_or_start_session(product.id, "+15557770001")
      {:ok, _} = Sms.escalate_session(session, "user upset")

      [escalation] = Escalations.list_open_for_product(product.id, [])

      conn = post(conn, ~p"/api/v1/escalations/#{escalation.id}/resolve", %{})
      assert %{"data" => %{"resolved" => true}} = json_response(conn, 200)

      reloaded = Repo.get!(ContentForge.Sms.ConversationSession, session.id)
      assert reloaded.escalated_at == nil
      assert reloaded.auto_response_paused == false
    end

    test "resolving an already-resolved escalation is a no-op success", %{
      conn: conn,
      product: product
    } do
      {:ok, event} =
        Escalations.create_or_update_open(%{
          product_id: product.id,
          session_id: "ops-3",
          channel: "openclaw_cli",
          reason: "needs human",
          holding_reply: "hold"
        })

      {:ok, _} = Escalations.mark_resolved(event, "operator-x")

      conn = post(conn, ~p"/api/v1/escalations/#{event.id}/resolve", %{})
      assert %{"data" => %{"resolved" => true}} = json_response(conn, 200)
    end

    test "after resolving, the dispatcher hook stops blocking the session", %{
      product: product
    } do
      {:ok, event} =
        Escalations.create_or_update_open(%{
          product_id: product.id,
          session_id: "dispatch-after-resolve",
          channel: "openclaw_cli",
          reason: "needs human",
          holding_reply: "hold"
        })

      assert %EscalationEvent{} = Escalations.find_open(product.id, "dispatch-after-resolve")
      {:ok, _} = Escalations.mark_resolved(event, "ops")
      assert nil == Escalations.find_open(product.id, "dispatch-after-resolve")
    end
  end
end
