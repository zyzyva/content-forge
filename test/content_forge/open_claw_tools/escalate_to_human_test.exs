defmodule ContentForge.OpenClawTools.EscalateToHumanTest do
  @moduledoc """
  Phase 16.6 escalate_to_human: agent self-escalates a session
  for human attention. Gated by `:viewer` (anyone authenticated
  can ask for help). Idempotent on re-escalation: a second call
  on an already-open session updates the existing event.
  """

  use ContentForge.DataCase, async: false

  alias ContentForge.Escalations
  alias ContentForge.Escalations.EscalationEvent
  alias ContentForge.OpenClawTools.EscalateToHuman
  alias ContentForge.Products
  alias ContentForge.Sms

  setup do
    {:ok, product} =
      Products.create_product(%{
        name: "Escalation Tool Product #{System.unique_integer()}",
        voice_profile: "professional"
      })

    %{product: product}
  end

  defp sms_ctx(phone, role, product, session_id \\ "sms-sess-1") do
    {:ok, _} =
      Sms.create_phone(%{
        product_id: product.id,
        phone_number: phone,
        role: role,
        active: true
      })

    %{
      channel: "sms",
      sender_identity: phone,
      session_id: session_id,
      product: product
    }
  end

  describe "call/2 happy path" do
    test "creates an EscalationEvent and returns the holding reply", %{product: product} do
      ctx = sms_ctx("+15551110001", "viewer", product)

      assert {:ok, result} =
               EscalateToHuman.call(ctx, %{
                 "product" => product.id,
                 "reason" => "User wants to discuss pricing for the Q3 plan"
               })

      assert result.product_id == product.id
      assert result.urgency == "normal"
      assert result.holding_reply =~ "follow up"
      assert result.channel == "openclaw_sms"
      assert is_binary(result.event_id)

      assert event = Repo.get(EscalationEvent, result.event_id)
      assert event.reason =~ "Q3 plan"
      assert event.resolved == false
    end

    test "honors the supplied urgency", %{product: product} do
      ctx = sms_ctx("+15551110002", "viewer", product)

      assert {:ok, %{urgency: "high"}} =
               EscalateToHuman.call(ctx, %{
                 "product" => product.id,
                 "reason" => "User is angry, asking for a refund",
                 "urgency" => "high"
               })
    end

    test "phone-shaped sender_identity is hashed in the persisted row", %{product: product} do
      ctx = sms_ctx("+15551110003", "viewer", product)

      {:ok, %{event_id: id}} =
        EscalateToHuman.call(ctx, %{
          "product" => product.id,
          "reason" => "ambiguity"
        })

      event = Repo.get(EscalationEvent, id)
      assert String.starts_with?(event.sender_identity, "sha256:")
      refute event.sender_identity =~ "5551110003"
    end

    test "is idempotent: re-escalating the same session updates the row in place", %{
      product: product
    } do
      ctx = sms_ctx("+15551110004", "viewer", product, "same-session")

      {:ok, %{event_id: first_id}} =
        EscalateToHuman.call(ctx, %{"product" => product.id, "reason" => "first reason"})

      {:ok, %{event_id: second_id}} =
        EscalateToHuman.call(ctx, %{
          "product" => product.id,
          "reason" => "user is now upset",
          "urgency" => "high"
        })

      assert first_id == second_id
      event = Repo.get(EscalationEvent, first_id)
      assert event.reason == "user is now upset"
      assert event.urgency == "high"
    end

    test "cli channel produces openclaw_cli channel on the event" do
      {:ok, product} =
        Products.create_product(%{
          name: "CLI Esc #{System.unique_integer()}",
          voice_profile: "professional"
        })

      {:ok, _operator} =
        ContentForge.Operators.create_identity(%{
          product_id: product.id,
          identity: "cli:ops",
          role: "viewer",
          active: true
        })

      ctx = %{
        channel: "cli",
        sender_identity: "cli:ops",
        session_id: "cli-sess-7",
        product: product
      }

      assert {:ok, %{channel: "openclaw_cli"}} =
               EscalateToHuman.call(ctx, %{
                 "product" => product.id,
                 "reason" => "user asked to talk to a human"
               })
    end
  end

  describe "validation" do
    test "missing reason returns :reason_required without inserting", %{product: product} do
      ctx = sms_ctx("+15552220001", "viewer", product)

      assert {:error, :reason_required} =
               EscalateToHuman.call(ctx, %{"product" => product.id})

      refute Escalations.find_open(product.id, ctx.session_id)
    end

    test "empty reason returns :reason_required", %{product: product} do
      ctx = sms_ctx("+15552220002", "viewer", product)

      assert {:error, :reason_required} =
               EscalateToHuman.call(ctx, %{"product" => product.id, "reason" => ""})
    end

    test "oversized reason returns :reason_too_long", %{product: product} do
      ctx = sms_ctx("+15552220003", "viewer", product)
      long = String.duplicate("a", 2_001)

      assert {:error, :reason_too_long} =
               EscalateToHuman.call(ctx, %{"product" => product.id, "reason" => long})
    end

    test "invalid urgency returns :invalid_urgency", %{product: product} do
      ctx = sms_ctx("+15552220004", "viewer", product)

      assert {:error, :invalid_urgency} =
               EscalateToHuman.call(ctx, %{
                 "product" => product.id,
                 "reason" => "valid reason",
                 "urgency" => "fubar"
               })
    end
  end

  describe "authorization" do
    test "missing product context returns :missing_product_context (no row inserted)" do
      ctx = %{channel: "cli", sender_identity: "cli:ops", session_id: "x"}

      assert {:error, :missing_product_context} =
               EscalateToHuman.call(ctx, %{"reason" => "vague"})
    end

    test "viewer role passes the auth gate", %{product: product} do
      ctx = sms_ctx("+15553330001", "viewer", product)

      assert {:ok, _} =
               EscalateToHuman.call(ctx, %{
                 "product" => product.id,
                 "reason" => "needs a human"
               })
    end
  end
end
