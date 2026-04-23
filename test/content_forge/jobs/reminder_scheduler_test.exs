defmodule ContentForge.Jobs.ReminderSchedulerTest do
  use ContentForge.DataCase, async: false
  use Oban.Testing, repo: ContentForge.Repo

  alias ContentForge.Jobs.ReminderDispatcher
  alias ContentForge.Jobs.ReminderScheduler
  alias ContentForge.Products
  alias ContentForge.Sms

  setup do
    {:ok, product} =
      Products.create_product(%{name: "Scheduled Product", voice_profile: "professional"})

    %{product: product}
  end

  defp create_phone!(product, phone_number \\ "+15551112222") do
    {:ok, phone} =
      Sms.create_phone(%{
        product_id: product.id,
        phone_number: phone_number,
        role: "owner"
      })

    phone
  end

  defp upsert_config!(product, attrs) do
    {:ok, cfg} = Sms.upsert_reminder_config(product.id, attrs)
    cfg
  end

  # An inbound event inserted_at `seconds_ago` seconds before now is used
  # to simulate a phone that has been silent for a given duration.
  defp record_silent_since!(product, phone, seconds_ago) do
    {:ok, event} =
      Sms.record_event(%{
        product_id: product.id,
        phone_number: phone.phone_number,
        direction: "inbound",
        status: "received",
        body: "hi"
      })

    # Manually backdate inserted_at since the changeset ignores overrides.
    ContentForge.Repo.update_all(
      from(e in Sms.SmsEvent, where: e.id == ^event.id),
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -seconds_ago, :second)]
    )

    event
  end

  defp run_scheduler_at(%DateTime{} = now_utc) do
    perform_job(ReminderScheduler, %{"now" => DateTime.to_iso8601(now_utc)})
  end

  describe "enqueues dispatcher when all gates pass" do
    test "cadence met, not paused, within allowed hours",
         %{product: product} do
      phone = create_phone!(product)

      # cadence_days=3, quiet_hours_start=20, quiet_hours_end=8, TZ UTC.
      upsert_config!(product, %{
        cadence_days: 3,
        quiet_hours_start: 20,
        quiet_hours_end: 8,
        timezone: "UTC"
      })

      # Last inbound 4 days ago.
      record_silent_since!(product, phone, 4 * 86_400)

      # Run scheduler at 14:00 UTC (inside allowed window).
      noonish =
        DateTime.utc_now()
        |> Map.put(:hour, 14)
        |> Map.put(:minute, 0)
        |> Map.put(:second, 0)

      assert :ok = run_scheduler_at(noonish)

      assert_enqueued(
        worker: ReminderDispatcher,
        args: %{"phone_id" => phone.id, "product_id" => product.id}
      )
    end
  end

  describe "skips when any gate blocks" do
    test "cadence not yet met", %{product: product} do
      phone = create_phone!(product)
      upsert_config!(product, %{cadence_days: 7})

      # Silent only 1 day.
      record_silent_since!(product, phone, 86_400)

      assert :ok =
               run_scheduler_at(DateTime.utc_now() |> Map.put(:hour, 14))

      refute_enqueued(worker: ReminderDispatcher)
    end

    test "phone paused (reminders_paused_until in future)", %{product: product} do
      phone = create_phone!(product)
      upsert_config!(product, %{cadence_days: 3})
      record_silent_since!(product, phone, 4 * 86_400)

      {:ok, _} = Sms.pause_phone_reminders(phone, 5)

      assert :ok =
               run_scheduler_at(DateTime.utc_now() |> Map.put(:hour, 14))

      refute_enqueued(worker: ReminderDispatcher)
    end

    test "outside quiet-hours window (3am local)", %{product: product} do
      phone = create_phone!(product)

      upsert_config!(product, %{
        cadence_days: 3,
        quiet_hours_start: 20,
        quiet_hours_end: 8,
        timezone: "UTC"
      })

      record_silent_since!(product, phone, 4 * 86_400)

      quiet_hour =
        DateTime.utc_now()
        |> Map.put(:hour, 3)
        |> Map.put(:minute, 0)
        |> Map.put(:second, 0)

      assert :ok = run_scheduler_at(quiet_hour)

      refute_enqueued(worker: ReminderDispatcher)
    end

    test "config disabled", %{product: product} do
      phone = create_phone!(product)
      upsert_config!(product, %{enabled: false, cadence_days: 3})
      record_silent_since!(product, phone, 4 * 86_400)

      assert :ok =
               run_scheduler_at(DateTime.utc_now() |> Map.put(:hour, 14))

      refute_enqueued(worker: ReminderDispatcher)

      _ = phone
    end

    test "product has no ReminderConfig", %{product: product} do
      _phone = create_phone!(product)

      assert :ok =
               run_scheduler_at(DateTime.utc_now() |> Map.put(:hour, 14))

      refute_enqueued(worker: ReminderDispatcher)
    end

    test "no inbound ever (skip for now; phone not yet engaged)",
         %{product: product} do
      _phone = create_phone!(product)
      upsert_config!(product, %{cadence_days: 3})

      assert :ok =
               run_scheduler_at(DateTime.utc_now() |> Map.put(:hour, 14))

      refute_enqueued(worker: ReminderDispatcher)
    end

    test "inactive phone is skipped", %{product: product} do
      phone = create_phone!(product)
      upsert_config!(product, %{cadence_days: 3})
      record_silent_since!(product, phone, 4 * 86_400)

      {:ok, _} = Sms.deactivate_phone(phone)

      assert :ok =
               run_scheduler_at(DateTime.utc_now() |> Map.put(:hour, 14))

      refute_enqueued(worker: ReminderDispatcher)
    end
  end

  describe "double-enqueue idempotency via Oban.unique" do
    test "two runs within the same 24h produce only one queued dispatcher",
         %{product: product} do
      phone = create_phone!(product)

      upsert_config!(product, %{
        cadence_days: 3,
        quiet_hours_start: 20,
        quiet_hours_end: 8
      })

      record_silent_since!(product, phone, 4 * 86_400)

      noon = DateTime.utc_now() |> Map.put(:hour, 14)

      assert :ok = run_scheduler_at(noon)
      assert :ok = run_scheduler_at(DateTime.add(noon, 60, :second))

      # Oban.unique collapses the second enqueue; exactly one dispatcher is
      # queued for this phone within the unique period.
      queued =
        Oban.Job
        |> Ecto.Query.where(worker: "ContentForge.Jobs.ReminderDispatcher")
        |> Ecto.Query.where(state: "available")
        |> ContentForge.Repo.all()

      assert length(queued) == 1
    end
  end
end
