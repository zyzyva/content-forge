defmodule ContentForge.Sms do
  @moduledoc """
  Context for the SMS side of Content Forge: product-scoped phone
  whitelist, inbound/outbound event audit log, and per-(product, phone)
  conversation state machine.

  This module owns persistence + queries for `ProductPhone`, `SmsEvent`,
  and `ConversationSession`. Webhook receivers (14.1b) and outreach
  workers (14.2+) are expected to call through here rather than hitting
  schemas directly.
  """

  import Ecto.Query

  alias ContentForge.Repo
  alias ContentForge.Sms.ConversationSession
  alias ContentForge.Sms.ProductPhone
  alias ContentForge.Sms.ReminderConfig
  alias ContentForge.Sms.SmsEvent

  @default_pause_days 7

  # ---- product phones (whitelist) ----------------------------------------

  @doc "Inserts a phone row. Returns `{:ok, row}` or `{:error, changeset}`."
  @spec create_phone(map()) :: {:ok, ProductPhone.t()} | {:error, Ecto.Changeset.t()}
  def create_phone(attrs) when is_map(attrs) do
    %ProductPhone{}
    |> ProductPhone.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Looks up a phone by (phone_number, product_id). Returns the
  `%ProductPhone{}` iff it exists AND is active. Returns nil otherwise,
  which covers both "not whitelisted" and "whitelisted but deactivated".
  """
  @spec lookup_phone(String.t(), Ecto.UUID.t()) :: ProductPhone.t() | nil
  def lookup_phone(phone_number, product_id)
      when is_binary(phone_number) and is_binary(product_id) do
    Repo.one(
      from(p in ProductPhone,
        where:
          p.phone_number == ^phone_number and
            p.product_id == ^product_id and
            p.active == true
      )
    )
  end

  @doc """
  Lists phones for a product. Options:

    * `:active` - `true` (default) returns only active rows; `false`
      returns only deactivated rows; `:all` returns both.
  """
  @spec list_phones_for_product(Ecto.UUID.t(), keyword()) :: [ProductPhone.t()]
  def list_phones_for_product(product_id, opts \\ []) when is_binary(product_id) do
    ProductPhone
    |> where([p], p.product_id == ^product_id)
    |> apply_active_filter(Keyword.get(opts, :active, true))
    |> order_by([p], asc: p.inserted_at)
    |> Repo.all()
  end

  defp apply_active_filter(query, :all), do: query
  defp apply_active_filter(query, true), do: where(query, [p], p.active == true)
  defp apply_active_filter(query, false), do: where(query, [p], p.active == false)

  @doc "Updates a phone row with arbitrary attributes."
  @spec update_phone(ProductPhone.t(), map()) ::
          {:ok, ProductPhone.t()} | {:error, Ecto.Changeset.t()}
  def update_phone(%ProductPhone{} = row, attrs) do
    row
    |> ProductPhone.changeset(attrs)
    |> Repo.update()
  end

  @doc "Flips a phone's `active` to false without touching the opt-in history."
  @spec deactivate_phone(ProductPhone.t()) ::
          {:ok, ProductPhone.t()} | {:error, Ecto.Changeset.t()}
  def deactivate_phone(%ProductPhone{} = row) do
    row
    |> ProductPhone.deactivate_changeset()
    |> Repo.update()
  end

  @doc """
  Finds a `%ProductPhone{}` row by `phone_number` across all products,
  preferring an active row. Returns `nil` when no row exists.

  Intended for webhook paths that receive a sender phone without a
  product scope; the caller uses `row.active` and `row.product_id` to
  decide between accept / inactive-reject / unknown-reject.
  """
  @spec lookup_phone_by_number(String.t()) :: ProductPhone.t() | nil
  def lookup_phone_by_number(phone_number) when is_binary(phone_number) do
    Repo.one(
      from(p in ProductPhone,
        where: p.phone_number == ^phone_number,
        order_by: [desc: p.active, asc: p.inserted_at],
        limit: 1
      )
    )
  end

  # ---- SMS events (audit log) --------------------------------------------

  @doc "Inserts an audit row for an inbound or outbound message."
  @spec record_event(map()) :: {:ok, SmsEvent.t()} | {:error, Ecto.Changeset.t()}
  def record_event(attrs) when is_map(attrs) do
    %SmsEvent{}
    |> SmsEvent.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Counts outbound `SmsEvent` rows for `phone_number` inserted within
  the last `seconds` window. Drives the per-phone daily rate limit in
  `ContentForge.Jobs.SmsReplyDispatcher`. Passes through on any
  `status` so `rejected_rate_limit` rows also count against the quota
  (they still represent a reply attempt).
  """
  @spec count_recent_outbound(String.t(), pos_integer()) :: non_neg_integer()
  def count_recent_outbound(phone_number, seconds \\ 86_400)
      when is_binary(phone_number) and is_integer(seconds) and seconds > 0 do
    since = DateTime.add(DateTime.utc_now(), -seconds, :second)

    Repo.aggregate(
      from(e in SmsEvent,
        where:
          e.phone_number == ^phone_number and
            e.direction == "outbound" and
            e.inserted_at >= ^since
      ),
      :count,
      :id
    )
  end

  @doc """
  Lists audit rows for a product. Options filter by `:direction`,
  `:status`, and `:phone_number`. Returns rows newest-first.
  """
  @spec list_events(Ecto.UUID.t() | nil, keyword()) :: [SmsEvent.t()]
  def list_events(product_id, opts \\ []) when is_list(opts) do
    SmsEvent
    |> apply_event_product(product_id)
    |> apply_event_direction(Keyword.get(opts, :direction))
    |> apply_event_status(Keyword.get(opts, :status))
    |> apply_event_phone(Keyword.get(opts, :phone_number))
    |> order_by([e], desc: e.inserted_at)
    |> Repo.all()
  end

  defp apply_event_product(query, nil), do: where(query, [e], is_nil(e.product_id))

  defp apply_event_product(query, product_id) when is_binary(product_id),
    do: where(query, [e], e.product_id == ^product_id)

  defp apply_event_direction(query, nil), do: query

  defp apply_event_direction(query, direction) when is_binary(direction),
    do: where(query, [e], e.direction == ^direction)

  defp apply_event_status(query, nil), do: query

  defp apply_event_status(query, status) when is_binary(status),
    do: where(query, [e], e.status == ^status)

  defp apply_event_phone(query, nil), do: query

  defp apply_event_phone(query, phone_number) when is_binary(phone_number),
    do: where(query, [e], e.phone_number == ^phone_number)

  # ---- conversation sessions (state machine) -----------------------------

  @doc """
  Idempotent lookup by (product_id, phone_number). Creates a new
  `"idle"` session if none exists; otherwise refreshes
  `last_message_at` on the existing row.
  """
  @spec get_or_start_session(Ecto.UUID.t(), String.t()) ::
          {:ok, ConversationSession.t()} | {:error, Ecto.Changeset.t()}
  def get_or_start_session(product_id, phone_number)
      when is_binary(product_id) and is_binary(phone_number) do
    now = DateTime.utc_now()

    case Repo.get_by(ConversationSession,
           product_id: product_id,
           phone_number: phone_number
         ) do
      nil ->
        %ConversationSession{}
        |> ConversationSession.changeset(%{
          product_id: product_id,
          phone_number: phone_number,
          state: "idle",
          last_message_at: now
        })
        |> Repo.insert()

      %ConversationSession{} = session ->
        session
        |> ConversationSession.changeset(%{last_message_at: now})
        |> Repo.update()
    end
  end

  @doc "Transitions a session's `state` to the given value."
  @spec set_session_state(ConversationSession.t(), String.t()) ::
          {:ok, ConversationSession.t()} | {:error, Ecto.Changeset.t()}
  def set_session_state(%ConversationSession{} = session, state) when is_binary(state) do
    session
    |> ConversationSession.changeset(%{state: state})
    |> Repo.update()
  end

  @doc """
  Marks `session` escalated: sets `escalated_at` to now, records the
  given `reason`, flips `auto_response_paused: true`, and writes an
  `SmsEvent` audit row with status `"escalated"` so downstream
  dashboards can surface the transition.

  `opts` currently only carries `:notify_channels`; the list is
  recorded on the audit row body so a future slice can fan out to
  Slack / email. For this slice the dashboard LiveView is the only
  consumer.
  """
  @spec escalate_session(ConversationSession.t(), String.t(), keyword()) ::
          {:ok, ConversationSession.t()} | {:error, Ecto.Changeset.t()}
  def escalate_session(%ConversationSession{} = session, reason, opts \\ [])
      when is_binary(reason) do
    now = DateTime.utc_now()
    notify_channels = Keyword.get(opts, :notify_channels, [])

    updated =
      session
      |> ConversationSession.changeset(%{
        escalated_at: now,
        escalation_reason: reason,
        auto_response_paused: true
      })
      |> Repo.update()

    case updated do
      {:ok, row} = ok ->
        {:ok, _} =
          record_event(%{
            product_id: row.product_id,
            phone_number: row.phone_number,
            direction: "inbound",
            status: "escalated",
            body: escalation_audit_body(reason, notify_channels)
          })

        ok

      err ->
        err
    end
  end

  defp escalation_audit_body(reason, []), do: "escalated: #{reason}"

  defp escalation_audit_body(reason, channels) when is_list(channels) do
    "escalated: #{reason} (notify: #{Enum.join(channels, ", ")})"
  end

  @doc """
  Clears escalation flags on `session`: `escalated_at: nil`,
  `escalation_reason: nil`, `auto_response_paused: false`.
  Auto-response resumes the next time an inbound lands.
  """
  @spec resolve_session(ConversationSession.t()) ::
          {:ok, ConversationSession.t()} | {:error, Ecto.Changeset.t()}
  def resolve_session(%ConversationSession{} = session) do
    session
    |> ConversationSession.changeset(%{
      escalated_at: nil,
      escalation_reason: nil,
      auto_response_paused: false
    })
    |> Repo.update()
  end

  @doc """
  Lists every currently-escalated `ConversationSession` across all
  products, newest-escalation-first. Used by the NeedsAttention
  dashboard.
  """
  @spec list_escalated_sessions() :: [ConversationSession.t()]
  def list_escalated_sessions do
    from(s in ConversationSession,
      where: not is_nil(s.escalated_at),
      order_by: [desc: s.escalated_at]
    )
    |> Repo.all()
  end

  @doc """
  Lists sessions that have received at least `threshold` inbound
  `"received"` events in the last `seconds` window with no outbound
  `"sent"`/`"delivered"` reply in that same window. Default threshold
  10 and window 24h. Excludes already-escalated sessions so the
  dashboard does not double-list a single conversation.
  """
  @spec list_high_volume_sessions(keyword()) :: [ConversationSession.t()]
  def list_high_volume_sessions(opts \\ []) do
    threshold = Keyword.get(opts, :threshold, 10)
    seconds = Keyword.get(opts, :seconds, 86_400)
    since = DateTime.add(DateTime.utc_now(), -seconds, :second)

    inbound_counts =
      from(e in SmsEvent,
        where:
          e.direction == "inbound" and
            e.status == "received" and
            e.inserted_at >= ^since and
            not is_nil(e.product_id),
        group_by: [e.product_id, e.phone_number],
        select: {e.product_id, e.phone_number, count(e.id)}
      )
      |> Repo.all()

    outbound_pairs =
      from(e in SmsEvent,
        where:
          e.direction == "outbound" and
            e.status in ["sent", "delivered"] and
            e.inserted_at >= ^since,
        group_by: [e.product_id, e.phone_number],
        select: {e.product_id, e.phone_number}
      )
      |> Repo.all()
      |> MapSet.new()

    qualifying =
      inbound_counts
      |> Enum.filter(fn {product_id, phone_number, count} ->
        count >= threshold and
          not MapSet.member?(outbound_pairs, {product_id, phone_number})
      end)
      |> Enum.map(fn {product_id, phone_number, _count} -> {product_id, phone_number} end)

    lookup_sessions(qualifying)
  end

  defp lookup_sessions([]), do: []

  defp lookup_sessions(pairs) do
    pairs
    |> Enum.flat_map(fn {product_id, phone_number} ->
      case Repo.get_by(ConversationSession,
             product_id: product_id,
             phone_number: phone_number
           ) do
        %ConversationSession{escalated_at: nil} = s -> [s]
        _ -> []
      end
    end)
    |> Enum.sort_by(& &1.last_message_at, {:desc, DateTime})
  end

  # ---- reminder config + phone pause -------------------------------------

  @doc """
  Returns the `%ReminderConfig{}` for a product. If no row exists,
  returns an unpersisted struct with schema defaults and `id: nil` so
  callers can read config without first creating a row.
  """
  @spec get_reminder_config(Ecto.UUID.t()) :: ReminderConfig.t()
  def get_reminder_config(product_id) when is_binary(product_id) do
    case Repo.get_by(ReminderConfig, product_id: product_id) do
      nil -> %ReminderConfig{product_id: product_id}
      %ReminderConfig{} = row -> row
    end
  end

  @doc """
  Upserts the reminder config for a product. On first call inserts;
  subsequent calls update the existing row in-place.
  """
  @spec upsert_reminder_config(Ecto.UUID.t(), map()) ::
          {:ok, ReminderConfig.t()} | {:error, Ecto.Changeset.t()}
  def upsert_reminder_config(product_id, attrs) when is_binary(product_id) and is_map(attrs) do
    full_attrs = Map.put(attrs, :product_id, product_id)

    case Repo.get_by(ReminderConfig, product_id: product_id) do
      nil ->
        %ReminderConfig{}
        |> ReminderConfig.changeset(full_attrs)
        |> Repo.insert()

      %ReminderConfig{} = row ->
        row
        |> ReminderConfig.changeset(full_attrs)
        |> Repo.update()
    end
  end

  @doc """
  Sets `reminders_paused_until` on `phone` to `now + pause_days *
  86_400` seconds. Default 7 days when no value is supplied.
  """
  @spec pause_phone_reminders(ProductPhone.t(), pos_integer()) ::
          {:ok, ProductPhone.t()} | {:error, Ecto.Changeset.t()}
  def pause_phone_reminders(%ProductPhone{} = phone, pause_days \\ @default_pause_days)
      when is_integer(pause_days) and pause_days > 0 do
    until =
      DateTime.utc_now()
      |> DateTime.add(pause_days * 86_400, :second)

    phone
    |> ProductPhone.changeset(%{reminders_paused_until: until})
    |> Repo.update()
  end

  @doc "Clears `reminders_paused_until` on `phone` to nil."
  @spec resume_phone_reminders(ProductPhone.t()) ::
          {:ok, ProductPhone.t()} | {:error, Ecto.Changeset.t()}
  def resume_phone_reminders(%ProductPhone{} = phone) do
    phone
    |> ProductPhone.changeset(%{reminders_paused_until: nil})
    |> Repo.update()
  end

  @doc """
  Returns the most recent inbound `"received"` `SmsEvent.inserted_at`
  for `(product_id, phone_number)`, or `nil` if none.
  """
  @spec last_inbound_at(Ecto.UUID.t(), String.t()) :: DateTime.t() | nil
  def last_inbound_at(product_id, phone_number)
      when is_binary(product_id) and is_binary(phone_number) do
    Repo.one(
      from(e in SmsEvent,
        where:
          e.product_id == ^product_id and
            e.phone_number == ^phone_number and
            e.direction == "inbound" and
            e.status == "received",
        order_by: [desc: e.inserted_at],
        limit: 1,
        select: e.inserted_at
      )
    )
  end

  @doc """
  Counts outbound reminders (`"sent"` or `"delivered"`) for
  `(product_id, phone_number)` since the most recent inbound
  `"received"` event. When there has been no inbound, every outbound
  event counts.
  """
  @spec consecutive_ignored_reminders(Ecto.UUID.t(), String.t()) :: non_neg_integer()
  def consecutive_ignored_reminders(product_id, phone_number)
      when is_binary(product_id) and is_binary(phone_number) do
    since = last_inbound_at(product_id, phone_number)

    SmsEvent
    |> where(
      [e],
      e.product_id == ^product_id and
        e.phone_number == ^phone_number and
        e.direction == "outbound" and
        e.status in ["sent", "delivered"]
    )
    |> apply_since(since)
    |> Repo.aggregate(:count, :id)
  end

  defp apply_since(query, nil), do: query

  defp apply_since(query, %DateTime{} = since),
    do: where(query, [e], e.inserted_at > ^since)

  # ---- session expiry (extends the conversation-session block above) -----

  @doc """
  Flips all non-idle sessions whose `last_message_at` is older than
  their `inactive_after_seconds` window back to `"idle"`. Runs in a
  single `update_all`; returns `{:ok, affected_count}`.

  `now` is injectable for tests.
  """
  @spec expire_stale_sessions(DateTime.t()) :: {:ok, non_neg_integer()}
  def expire_stale_sessions(now \\ DateTime.utc_now()) do
    query =
      from(s in ConversationSession,
        where:
          s.state != "idle" and
            not is_nil(s.last_message_at) and
            fragment(
              "? + (? * interval '1 second') < ?",
              s.last_message_at,
              s.inactive_after_seconds,
              ^now
            )
      )

    {affected, _} = Repo.update_all(query, set: [state: "idle"])
    {:ok, affected}
  end
end
