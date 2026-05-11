defmodule ContentForge.EscalationsTest do
  use ContentForge.DataCase, async: false

  alias ContentForge.Escalations
  alias ContentForge.Escalations.EscalationEvent
  alias ContentForge.Products

  defp product!(name \\ "Escalation Product") do
    {:ok, p} =
      Products.create_product(%{
        name: "#{name} #{System.unique_integer()}",
        voice_profile: "professional"
      })

    p
  end

  defp base_attrs(product, overrides \\ %{}) do
    Map.merge(
      %{
        product_id: product.id,
        session_id: "sess-1",
        channel: "openclaw_cli",
        reason: "user is asking about pricing",
        holding_reply: "Thanks - someone will follow up.",
        urgency: "normal"
      },
      overrides
    )
  end

  describe "create_or_update_open/1" do
    test "inserts a new open escalation when none exists" do
      product = product!()

      assert {:ok, %EscalationEvent{} = event} =
               Escalations.create_or_update_open(base_attrs(product))

      assert event.product_id == product.id
      assert event.resolved == false
      assert event.urgency == "normal"
      assert event.reason =~ "pricing"
      assert event.holding_reply =~ "follow up"
    end

    test "is idempotent on re-escalation: updates the existing open row" do
      product = product!()
      {:ok, first} = Escalations.create_or_update_open(base_attrs(product))

      {:ok, updated} =
        Escalations.create_or_update_open(
          base_attrs(product, %{
            reason: "user is now upset",
            urgency: "high",
            holding_reply: "Updated holding reply"
          })
        )

      assert updated.id == first.id
      assert updated.reason == "user is now upset"
      assert updated.urgency == "high"
      assert updated.holding_reply == "Updated holding reply"
      assert Repo.aggregate(EscalationEvent, :count) == 1
    end

    test "after resolving the prior open row, a new escalation creates a fresh row" do
      product = product!()
      {:ok, first} = Escalations.create_or_update_open(base_attrs(product))
      {:ok, _resolved} = Escalations.mark_resolved(first, "operator-a")

      {:ok, second} = Escalations.create_or_update_open(base_attrs(product))

      assert second.id != first.id
      assert Repo.aggregate(EscalationEvent, :count) == 2
    end

    test "different sessions produce distinct rows even on the same product" do
      product = product!()
      {:ok, _a} = Escalations.create_or_update_open(base_attrs(product, %{session_id: "s-A"}))
      {:ok, _b} = Escalations.create_or_update_open(base_attrs(product, %{session_id: "s-B"}))
      assert Repo.aggregate(EscalationEvent, :count) == 2
    end

    test "phone-shaped sender_identity is hashed before insert; cli identity passes through" do
      product = product!()

      {:ok, sms_event} =
        Escalations.create_or_update_open(
          base_attrs(product, %{
            session_id: "phone-sess",
            channel: "sms",
            sender_identity: "+15551234567"
          })
        )

      {:ok, cli_event} =
        Escalations.create_or_update_open(
          base_attrs(product, %{
            session_id: "cli-sess",
            channel: "openclaw_cli",
            sender_identity: "cli:ops"
          })
        )

      assert String.starts_with?(sms_event.sender_identity, "sha256:")
      refute sms_event.sender_identity =~ "5551234567"
      assert cli_event.sender_identity == "cli:ops"
    end

    test "validates required fields and reason length" do
      product = product!()

      assert {:error, %Ecto.Changeset{}} =
               Escalations.create_or_update_open(%{product_id: product.id})

      long = String.duplicate("a", 2_001)

      assert {:error, %Ecto.Changeset{}} =
               Escalations.create_or_update_open(base_attrs(product, %{reason: long}))
    end

    test "validates urgency inclusion" do
      product = product!()

      assert {:error, %Ecto.Changeset{}} =
               Escalations.create_or_update_open(base_attrs(product, %{urgency: "fubar"}))
    end
  end

  describe "find_open/3" do
    test "returns the open row when present" do
      product = product!()
      {:ok, event} = Escalations.create_or_update_open(base_attrs(product))

      found = Escalations.find_open(product.id, "sess-1")
      assert found.id == event.id
    end

    test "returns nil when no open row exists" do
      product = product!()
      assert nil == Escalations.find_open(product.id, "no-such-session")
    end

    test "returns nil when the only matching row is resolved" do
      product = product!()
      {:ok, event} = Escalations.create_or_update_open(base_attrs(product))
      {:ok, _} = Escalations.mark_resolved(event, "auto")
      assert nil == Escalations.find_open(product.id, "sess-1")
    end

    test "with :max_age_seconds, returns nil for rows older than the window" do
      product = product!()
      {:ok, event} = Escalations.create_or_update_open(base_attrs(product))

      stale_at = DateTime.add(DateTime.utc_now(), -7200, :second)

      Repo.update_all(
        from(e in EscalationEvent, where: e.id == ^event.id),
        set: [inserted_at: stale_at]
      )

      assert nil ==
               Escalations.find_open(product.id, "sess-1", max_age_seconds: 3600)

      # Without the window, the row is still surfaced for operator triage.
      assert %EscalationEvent{} = Escalations.find_open(product.id, "sess-1")
    end
  end

  describe "list_open_for_product/2" do
    test "returns open rows newest-first; excludes resolved" do
      product = product!()

      {:ok, a} = Escalations.create_or_update_open(base_attrs(product, %{session_id: "s1"}))
      {:ok, b} = Escalations.create_or_update_open(base_attrs(product, %{session_id: "s2"}))
      {:ok, c} = Escalations.create_or_update_open(base_attrs(product, %{session_id: "s3"}))
      {:ok, _} = Escalations.mark_resolved(a, "operator")

      ids = Escalations.list_open_for_product(product.id, []) |> Enum.map(& &1.id)
      assert ids == [c.id, b.id]
    end

    test "limit caps result count" do
      product = product!()

      for i <- 1..3 do
        {:ok, _} =
          Escalations.create_or_update_open(base_attrs(product, %{session_id: "s#{i}"}))
      end

      assert length(Escalations.list_open_for_product(product.id, limit: 2)) == 2
    end
  end

  describe "mark_resolved/2" do
    test "flips resolved=true and records resolved_at + resolved_by" do
      product = product!()
      {:ok, event} = Escalations.create_or_update_open(base_attrs(product))

      {:ok, resolved} = Escalations.mark_resolved(event, "operator-bob")

      assert resolved.resolved == true
      assert %DateTime{} = resolved.resolved_at
      assert resolved.resolved_by == "operator-bob"
    end
  end
end
