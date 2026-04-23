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
  alias ContentForge.Sms.SmsEvent

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
