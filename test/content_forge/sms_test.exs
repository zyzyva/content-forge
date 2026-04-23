defmodule ContentForge.SmsTest do
  use ContentForge.DataCase, async: false

  alias ContentForge.Products
  alias ContentForge.Sms
  alias ContentForge.Sms.ConversationSession
  alias ContentForge.Sms.ProductPhone
  alias ContentForge.Sms.SmsEvent

  defp create_product!(name \\ "SMS Test Product") do
    {:ok, product} = Products.create_product(%{name: name, voice_profile: "professional"})
    product
  end

  defp phone_attrs(product, overrides) do
    Map.merge(
      %{
        product_id: product.id,
        phone_number: "+15551234567",
        role: "owner"
      },
      overrides
    )
  end

  describe "create_phone/1" do
    test "inserts a whitelisted phone with default active: true" do
      product = create_product!()

      assert {:ok, %ProductPhone{} = row} =
               Sms.create_phone(phone_attrs(product, %{}))

      assert row.product_id == product.id
      assert row.phone_number == "+15551234567"
      assert row.role == "owner"
      assert row.active == true
      assert row.opt_in_at == nil
    end

    test "rejects a non-E.164 phone number" do
      product = create_product!()

      assert {:error, changeset} =
               Sms.create_phone(phone_attrs(product, %{phone_number: "555-123-4567"}))

      assert Enum.any?(errors_on(changeset).phone_number, &String.contains?(&1, "E.164"))
    end

    test "rejects an unknown role" do
      product = create_product!()

      assert {:error, changeset} =
               Sms.create_phone(phone_attrs(product, %{role: "admin"}))

      assert "is invalid" in errors_on(changeset).role
    end

    test "rejects duplicate phone for the same product" do
      product = create_product!()
      {:ok, _} = Sms.create_phone(phone_attrs(product, %{}))

      assert {:error, changeset} =
               Sms.create_phone(phone_attrs(product, %{role: "viewer"}))

      all_errors = errors_on(changeset) |> Map.values() |> List.flatten()
      assert Enum.any?(all_errors, &(&1 =~ "already"))
    end
  end

  describe "lookup_phone/2" do
    test "returns the active phone row for (phone, product_id)" do
      product = create_product!()
      {:ok, row} = Sms.create_phone(phone_attrs(product, %{}))

      assert Sms.lookup_phone("+15551234567", product.id).id == row.id
    end

    test "returns nil for an unknown phone" do
      product = create_product!()
      assert Sms.lookup_phone("+15550000000", product.id) == nil
    end

    test "returns nil for a deactivated phone" do
      product = create_product!()
      {:ok, row} = Sms.create_phone(phone_attrs(product, %{}))
      {:ok, _} = Sms.deactivate_phone(row)

      assert Sms.lookup_phone("+15551234567", product.id) == nil
    end

    test "is scoped by product" do
      product_a = create_product!("A")
      product_b = create_product!("B")
      {:ok, _} = Sms.create_phone(phone_attrs(product_a, %{}))

      assert Sms.lookup_phone("+15551234567", product_a.id).product_id == product_a.id
      assert Sms.lookup_phone("+15551234567", product_b.id) == nil
    end
  end

  describe "list_phones_for_product/2" do
    test "returns active phones by default" do
      product = create_product!()

      {:ok, _active} = Sms.create_phone(phone_attrs(product, %{phone_number: "+15550000001"}))
      {:ok, inactive} = Sms.create_phone(phone_attrs(product, %{phone_number: "+15550000002"}))
      {:ok, _} = Sms.deactivate_phone(inactive)

      phones = Sms.list_phones_for_product(product.id)
      assert length(phones) == 1
      assert Enum.all?(phones, & &1.active)
    end

    test "returns inactive phones when active: false passed" do
      product = create_product!()

      {:ok, inactive} = Sms.create_phone(phone_attrs(product, %{}))
      {:ok, _} = Sms.deactivate_phone(inactive)

      phones = Sms.list_phones_for_product(product.id, active: false)
      assert length(phones) == 1
      assert hd(phones).active == false
    end

    test "returns all phones when active: :all passed" do
      product = create_product!()

      {:ok, _active} = Sms.create_phone(phone_attrs(product, %{phone_number: "+15550000001"}))
      {:ok, inactive} = Sms.create_phone(phone_attrs(product, %{phone_number: "+15550000002"}))
      {:ok, _} = Sms.deactivate_phone(inactive)

      assert length(Sms.list_phones_for_product(product.id, active: :all)) == 2
    end
  end

  describe "update_phone/2" do
    test "updates opt_in_at and opt_in_source" do
      product = create_product!()
      {:ok, row} = Sms.create_phone(phone_attrs(product, %{}))
      ts = DateTime.utc_now()

      assert {:ok, updated} =
               Sms.update_phone(row, %{opt_in_at: ts, opt_in_source: "reply_yes"})

      assert DateTime.compare(updated.opt_in_at, ts) == :eq
      assert updated.opt_in_source == "reply_yes"
    end
  end

  describe "record_event/1" do
    test "inserts an inbound received event" do
      product = create_product!()

      assert {:ok, %SmsEvent{} = event} =
               Sms.record_event(%{
                 product_id: product.id,
                 phone_number: "+15551234567",
                 direction: "inbound",
                 body: "hi from the phone",
                 status: "received",
                 twilio_sid: "SMxxx1"
               })

      assert event.direction == "inbound"
      assert event.status == "received"
      assert event.media_urls == []
    end

    test "inserts a rejected event with nil product_id (unknown number)" do
      assert {:ok, event} =
               Sms.record_event(%{
                 phone_number: "+15550000000",
                 direction: "inbound",
                 status: "rejected_unknown_number"
               })

      assert event.product_id == nil
      assert event.status == "rejected_unknown_number"
    end

    test "rejects an invalid direction" do
      product = create_product!()

      assert {:error, changeset} =
               Sms.record_event(%{
                 product_id: product.id,
                 phone_number: "+15551234567",
                 direction: "sideways",
                 status: "received"
               })

      assert "is invalid" in errors_on(changeset).direction
    end
  end

  describe "list_events/2" do
    test "filters by product_id and direction" do
      product = create_product!()

      {:ok, _in} =
        Sms.record_event(%{
          product_id: product.id,
          phone_number: "+15551234567",
          direction: "inbound",
          status: "received"
        })

      {:ok, _out} =
        Sms.record_event(%{
          product_id: product.id,
          phone_number: "+15551234567",
          direction: "outbound",
          status: "sent"
        })

      inbound = Sms.list_events(product.id, direction: "inbound")
      outbound = Sms.list_events(product.id, direction: "outbound")

      assert length(inbound) == 1
      assert length(outbound) == 1
    end

    test "filters by phone_number" do
      product = create_product!()

      {:ok, _} =
        Sms.record_event(%{
          product_id: product.id,
          phone_number: "+15550000001",
          direction: "inbound",
          status: "received"
        })

      {:ok, _} =
        Sms.record_event(%{
          product_id: product.id,
          phone_number: "+15550000002",
          direction: "inbound",
          status: "received"
        })

      rows = Sms.list_events(product.id, phone_number: "+15550000001")
      assert length(rows) == 1
      assert hd(rows).phone_number == "+15550000001"
    end
  end

  describe "get_or_start_session/2" do
    test "creates a new idle session on first touch" do
      product = create_product!()

      assert {:ok, %ConversationSession{} = session} =
               Sms.get_or_start_session(product.id, "+15551234567")

      assert session.state == "idle"
      assert session.product_id == product.id
      assert session.phone_number == "+15551234567"
      assert session.last_message_at != nil
    end

    test "returns the existing session and refreshes last_message_at" do
      product = create_product!()
      {:ok, first} = Sms.get_or_start_session(product.id, "+15551234567")
      Process.sleep(5)

      {:ok, second} = Sms.get_or_start_session(product.id, "+15551234567")

      assert second.id == first.id
      assert DateTime.compare(second.last_message_at, first.last_message_at) == :gt
    end
  end

  describe "set_session_state/2" do
    test "transitions the state" do
      product = create_product!()
      {:ok, session} = Sms.get_or_start_session(product.id, "+15551234567")

      assert {:ok, updated} = Sms.set_session_state(session, "waiting_for_upload")
      assert updated.state == "waiting_for_upload"
    end

    test "rejects unknown states" do
      product = create_product!()
      {:ok, session} = Sms.get_or_start_session(product.id, "+15551234567")

      assert {:error, changeset} = Sms.set_session_state(session, "enraged")
      assert "is invalid" in errors_on(changeset).state
    end
  end

  describe "expire_stale_sessions/1" do
    test "flips non-idle sessions whose last_message_at is past the inactive window to idle" do
      product = create_product!()

      # Session far past its inactive window (last_message_at 2 hours ago,
      # default inactive_after_seconds = 3600).
      old_ts = DateTime.add(DateTime.utc_now(), -2 * 3600, :second)

      {:ok, session} = Sms.get_or_start_session(product.id, "+15551234567")
      {:ok, session} = Sms.set_session_state(session, "waiting_for_upload")

      Repo.update_all(
        from(s in ConversationSession, where: s.id == ^session.id),
        set: [last_message_at: old_ts]
      )

      assert {:ok, 1} = Sms.expire_stale_sessions()

      assert Repo.get!(ConversationSession, session.id).state == "idle"
    end

    test "leaves fresh sessions alone" do
      product = create_product!()
      {:ok, session} = Sms.get_or_start_session(product.id, "+15551234567")
      {:ok, _} = Sms.set_session_state(session, "waiting_for_upload")

      assert {:ok, 0} = Sms.expire_stale_sessions()
      assert Repo.get!(ConversationSession, session.id).state == "waiting_for_upload"
    end

    test "leaves already-idle sessions alone" do
      product = create_product!()
      {:ok, session} = Sms.get_or_start_session(product.id, "+15551234567")

      old_ts = DateTime.add(DateTime.utc_now(), -2 * 3600, :second)

      Repo.update_all(
        from(s in ConversationSession, where: s.id == ^session.id),
        set: [last_message_at: old_ts]
      )

      assert {:ok, 0} = Sms.expire_stale_sessions()
    end
  end

  describe "cascade / nilify" do
    test "deleting a product removes its phones and sessions but nilifies its events" do
      product = create_product!("Doomed")
      {:ok, _phone} = Sms.create_phone(phone_attrs(product, %{}))
      {:ok, _session} = Sms.get_or_start_session(product.id, "+15551234567")

      {:ok, _event} =
        Sms.record_event(%{
          product_id: product.id,
          phone_number: "+15551234567",
          direction: "inbound",
          status: "received"
        })

      Repo.delete!(product)

      assert [] = Repo.all(from(p in ProductPhone, where: p.product_id == ^product.id))

      assert [] =
               Repo.all(from(s in ConversationSession, where: s.product_id == ^product.id))

      # The audit row survives with product_id nilified.
      assert [event] = Repo.all(from(e in SmsEvent))
      assert event.product_id == nil
      assert event.phone_number == "+15551234567"
    end
  end
end
