defmodule ContentForge.Sms.ReminderConfigTest do
  use ContentForge.DataCase, async: false

  alias ContentForge.Products
  alias ContentForge.Sms
  alias ContentForge.Sms.ProductPhone
  alias ContentForge.Sms.ReminderConfig

  defp create_product!(name \\ "Reminder Product") do
    {:ok, product} = Products.create_product(%{name: name, voice_profile: "professional"})
    product
  end

  defp create_phone!(product, overrides \\ %{}) do
    defaults = %{
      product_id: product.id,
      phone_number: "+15551112222",
      role: "owner"
    }

    {:ok, phone} = Sms.create_phone(Map.merge(defaults, overrides))
    phone
  end

  describe "get_reminder_config/1" do
    test "returns a default struct when no row exists" do
      product = create_product!()
      config = Sms.get_reminder_config(product.id)

      assert %ReminderConfig{} = config
      assert config.product_id == product.id
      assert config.enabled == true
      assert config.cadence_days == 7
      assert config.quiet_hours_start == 20
      assert config.quiet_hours_end == 8
      assert config.timezone == "UTC"
      assert config.backoff_after_ignored == 2
      assert config.stop_after_ignored == 4
      # Not persisted yet.
      assert config.id == nil
    end

    test "returns the persisted row when present" do
      product = create_product!()

      {:ok, persisted} =
        Sms.upsert_reminder_config(product.id, %{
          cadence_days: 3,
          quiet_hours_start: 21,
          timezone: "America/Los_Angeles"
        })

      got = Sms.get_reminder_config(product.id)

      assert got.id == persisted.id
      assert got.cadence_days == 3
      assert got.quiet_hours_start == 21
      assert got.timezone == "America/Los_Angeles"
    end
  end

  describe "upsert_reminder_config/2" do
    test "inserts on first call, updates on subsequent calls" do
      product = create_product!()

      {:ok, created} =
        Sms.upsert_reminder_config(product.id, %{cadence_days: 5})

      assert created.cadence_days == 5

      {:ok, updated} =
        Sms.upsert_reminder_config(product.id, %{cadence_days: 10, timezone: "UTC"})

      assert updated.id == created.id
      assert updated.cadence_days == 10
      assert updated.timezone == "UTC"
    end

    test "rejects invalid quiet-hours bounds" do
      product = create_product!()

      assert {:error, changeset} =
               Sms.upsert_reminder_config(product.id, %{quiet_hours_start: 30})

      assert Enum.any?(errors_on(changeset).quiet_hours_start, &(&1 =~ "23"))
    end
  end

  describe "pause_phone_reminders/2" do
    test "sets reminders_paused_until to now + pause_days * 86_400 seconds" do
      product = create_product!()
      phone = create_phone!(product)

      before_pause = DateTime.utc_now()
      assert {:ok, paused} = Sms.pause_phone_reminders(phone, 7)
      after_pause = DateTime.utc_now()

      diff_from_now =
        DateTime.diff(paused.reminders_paused_until, before_pause, :second)

      # 7 days -> 604_800 seconds, give or take the clock skew between
      # `before_pause` and when the helper read its own "now".
      assert diff_from_now >= 7 * 86_400 - 5
      assert diff_from_now <= 7 * 86_400 + DateTime.diff(after_pause, before_pause, :second) + 5

      assert Repo.get!(ProductPhone, phone.id).reminders_paused_until != nil
    end

    test "default pause duration is 7 days" do
      product = create_product!()
      phone = create_phone!(product)

      assert {:ok, paused} = Sms.pause_phone_reminders(phone)

      diff = DateTime.diff(paused.reminders_paused_until, DateTime.utc_now(), :second)
      assert diff >= 7 * 86_400 - 10
      assert diff <= 7 * 86_400 + 10
    end
  end

  describe "resume_phone_reminders/1" do
    test "clears reminders_paused_until to nil" do
      product = create_product!()
      phone = create_phone!(product)
      {:ok, paused} = Sms.pause_phone_reminders(phone, 7)
      assert paused.reminders_paused_until != nil

      assert {:ok, resumed} = Sms.resume_phone_reminders(paused)
      assert resumed.reminders_paused_until == nil
      assert Repo.get!(ProductPhone, phone.id).reminders_paused_until == nil
    end

    test "resume is a no-op on an already-resumed phone" do
      product = create_product!()
      phone = create_phone!(product)

      assert {:ok, row} = Sms.resume_phone_reminders(phone)
      assert row.reminders_paused_until == nil
    end
  end
end
