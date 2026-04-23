defmodule ContentForge.Jobs.ReminderScheduler do
  @moduledoc """
  Hourly scheduler that enqueues `ContentForge.Jobs.ReminderDispatcher`
  for each (product, phone) pair that is due for a reminder.

  A dispatcher is enqueued when ALL of these gates pass:

    1. The product has a `ReminderConfig` with `enabled: true`.
    2. The phone is active (`product_phones.active = true`).
    3. `reminders_paused_until` is nil or in the past.
    4. The most recent inbound `"received"` event is older than
       `cadence_days` (phones with no inbound yet are skipped; the
       system only nudges engaged senders, never cold outreach).
    5. The current local hour in the product's timezone is outside
       the `[quiet_hours_start, quiet_hours_end)` quiet window.
       Non-UTC timezones fall back to UTC when no tz database is
       loaded; this is acceptable under the solo-dev / single-tenant
       regime and documented here for the future tz-db slice.

  Double-enqueue is guarded by `Oban.unique` keyed on the dispatcher's
  phone_id + product_id with a 24h window. Two scheduler runs inside
  the same 24h produce at most one queued dispatcher per phone.

  The `now` arg is injectable (ISO 8601 string) so tests can simulate
  different hours of day without waiting for the wall clock.
  """
  use Oban.Worker, queue: :default, max_attempts: 3
  require Logger

  import Ecto.Query, warn: false

  alias ContentForge.Jobs.ReminderDispatcher
  alias ContentForge.Products.Product
  alias ContentForge.Sms
  alias ContentForge.Sms.ProductPhone
  alias ContentForge.Sms.ReminderConfig

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    now = parse_now(args["now"]) || DateTime.utc_now()

    configs = load_enabled_configs()
    total = enqueue_for_configs(configs, now)

    Logger.info("ReminderScheduler: evaluated #{length(configs)} configs; enqueued #{total}")

    :ok
  end

  defp parse_now(nil), do: nil

  defp parse_now(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  # --- config + phone loading --------------------------------------------

  defp load_enabled_configs do
    from(c in ReminderConfig,
      where: c.enabled == true,
      join: p in Product,
      on: c.product_id == p.id,
      select: {p, c}
    )
    |> ContentForge.Repo.all()
  end

  defp enqueue_for_configs(configs, now) do
    Enum.reduce(configs, 0, fn {product, config}, acc ->
      acc + enqueue_for_product(product, config, now)
    end)
  end

  defp enqueue_for_product(product, config, now) do
    if sendable_hour?(now, config) do
      product
      |> active_phones()
      |> Enum.reduce(0, fn phone, acc ->
        acc + maybe_enqueue(phone, product, config, now)
      end)
    else
      0
    end
  end

  defp active_phones(product) do
    Sms.list_phones_for_product(product.id)
  end

  # --- per-phone eligibility ---------------------------------------------

  defp maybe_enqueue(%ProductPhone{} = phone, product, config, now) do
    cond do
      phone_paused?(phone, now) -> 0
      not cadence_met?(phone, product, config, now) -> 0
      true -> enqueue_dispatcher(phone, product)
    end
  end

  defp phone_paused?(%ProductPhone{reminders_paused_until: nil}, _now), do: false

  defp phone_paused?(%ProductPhone{reminders_paused_until: until}, now),
    do: DateTime.compare(until, now) == :gt

  defp cadence_met?(phone, product, config, now) do
    case Sms.last_inbound_at(product.id, phone.phone_number) do
      nil ->
        # Never engaged - do not send. The system only nudges engaged
        # senders; cold outreach is a separate channel.
        false

      %DateTime{} = last ->
        DateTime.diff(now, last, :second) >= config.cadence_days * 86_400
    end
  end

  defp enqueue_dispatcher(%ProductPhone{} = phone, product) do
    case %{"phone_id" => phone.id, "product_id" => product.id}
         |> ReminderDispatcher.new(
           unique: [
             period: 86_400,
             keys: [:phone_id, :product_id],
             states: [:available, :scheduled, :executing, :retryable]
           ]
         )
         |> Oban.insert() do
      {:ok, %Oban.Job{conflict?: true}} -> 0
      {:ok, _job} -> 1
      {:error, _} -> 0
    end
  end

  # --- quiet hours --------------------------------------------------------

  defp sendable_hour?(now, %ReminderConfig{
         quiet_hours_start: qs,
         quiet_hours_end: qe,
         timezone: tz
       }) do
    hour = local_hour(now, tz)
    not quiet?(hour, qs, qe)
  end

  defp local_hour(%DateTime{} = now, "UTC"), do: now.hour

  defp local_hour(%DateTime{} = now, tz) do
    case DateTime.shift_zone(now, tz) do
      {:ok, local} ->
        local.hour

      {:error, _} ->
        # No tz database loaded; fall back to UTC. Documented in the
        # moduledoc as a known limitation for the solo-dev regime.
        now.hour
    end
  end

  # When qs > qe the quiet window crosses midnight: quiet = [qs, 24) ∪ [0, qe).
  defp quiet?(hour, qs, qe) when qs > qe, do: hour >= qs or hour < qe

  # When qs <= qe the quiet window is a single interval [qs, qe).
  defp quiet?(hour, qs, qe), do: hour >= qs and hour < qe
end
