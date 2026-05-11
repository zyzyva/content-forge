defmodule ContentForge.Escalations do
  @moduledoc """
  Phase 16.6 cross-channel escalation context.

  Backs the `escalate_to_human` tool, the dispatcher
  short-circuit hooks (in `ContentForge.OpenClawTools` and
  `ContentForgeMCP.Server`), and the channel-agnostic operator
  dashboard. Reuses the 16.5 PII helper
  (`ContentForge.ToolAudit.hash_pii/1`) so phone-shaped sender
  identities are stored hashed at the same prefix the audit
  surface uses.

  ## Idempotent re-escalation

  `create_or_update_open/1` is the only insert path. If an open
  escalation already exists for `(product_id, session_id)`, the
  call updates the existing row's `reason`, `urgency`, and
  `holding_reply` instead of creating a duplicate. The partial
  unique index `escalation_events_one_open_per_session_index`
  is the database-level guarantee.

  ## Auto-expiry

  `find_open/3` accepts an optional `:max_age_seconds`. When
  set, rows older than the window return as `nil` (no longer
  blocking) but stay in the table as audit records.
  """

  import Ecto.Query

  alias ContentForge.Escalations.EscalationEvent
  alias ContentForge.Repo
  alias ContentForge.ToolAudit

  @phone_pattern ~r/^\+\d{7,15}$/

  @doc """
  Inserts a new open escalation, or updates an existing open row
  for the same `(product_id, session_id)`.
  """
  @spec create_or_update_open(map()) ::
          {:ok, EscalationEvent.t()} | {:error, Ecto.Changeset.t()}
  def create_or_update_open(attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)
    do_create_or_update(find_open_row(attrs[:product_id], attrs[:session_id]), attrs)
  end

  defp do_create_or_update(nil, attrs) do
    %EscalationEvent{}
    |> EscalationEvent.create_changeset(attrs)
    |> Repo.insert()
  end

  defp do_create_or_update(%EscalationEvent{} = existing, attrs) do
    existing
    |> EscalationEvent.reescalate_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Returns the open `EscalationEvent` for `(product_id, session_id)`
  or `nil`.

  Options:

    * `:max_age_seconds` - when set, rows whose `inserted_at`
      is older than `now - max_age_seconds` are treated as
      expired and return as `nil`.
  """
  @spec find_open(binary() | nil, String.t() | nil, keyword()) :: EscalationEvent.t() | nil
  def find_open(product_id, session_id, opts \\ [])

  def find_open(nil, _session_id, _opts), do: nil
  def find_open(_product_id, nil, _opts), do: nil

  def find_open(product_id, session_id, opts) do
    product_id
    |> find_open_row(session_id)
    |> respect_max_age(Keyword.get(opts, :max_age_seconds))
  end

  defp find_open_row(nil, _session_id), do: nil
  defp find_open_row(_product_id, nil), do: nil

  defp find_open_row(product_id, session_id) do
    EscalationEvent
    |> where([e], e.product_id == ^product_id)
    |> where([e], e.session_id == ^session_id)
    |> where([e], e.resolved == false)
    |> Repo.one()
  end

  defp respect_max_age(nil, _max_age), do: nil
  defp respect_max_age(event, nil), do: event

  defp respect_max_age(%EscalationEvent{inserted_at: inserted_at} = event, max_age)
       when is_integer(max_age) and max_age > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -max_age, :second)

    if DateTime.compare(inserted_at, cutoff) == :lt do
      nil
    else
      event
    end
  end

  @doc """
  Lists open escalations for a product, newest-first.

  Options:

    * `:limit` - cap row count (default 100)
  """
  @spec list_open_for_product(binary(), keyword()) :: [EscalationEvent.t()]
  def list_open_for_product(product_id, opts) when is_binary(product_id) do
    EscalationEvent
    |> where([e], e.product_id == ^product_id)
    |> where([e], e.resolved == false)
    |> order_by([e], desc: e.inserted_at)
    |> limit(^Keyword.get(opts, :limit, 100))
    |> Repo.all()
  end

  @doc """
  Lists open escalations across all products, newest-first.
  Used by the channel-agnostic SMS needs-attention dashboard.
  """
  @spec list_open(keyword()) :: [EscalationEvent.t()]
  def list_open(opts \\ []) do
    EscalationEvent
    |> where([e], e.resolved == false)
    |> order_by([e], desc: e.inserted_at)
    |> limit(^Keyword.get(opts, :limit, 200))
    |> Repo.all()
  end

  @doc """
  Marks an escalation resolved, recording who closed it.
  """
  @spec mark_resolved(EscalationEvent.t(), String.t() | nil) ::
          {:ok, EscalationEvent.t()} | {:error, Ecto.Changeset.t()}
  def mark_resolved(%EscalationEvent{} = event, resolved_by) do
    event
    |> EscalationEvent.resolve_changeset(%{
      resolved: true,
      resolved_at: DateTime.utc_now(),
      resolved_by: resolved_by
    })
    |> Repo.update()
  end

  @doc "Fetches an `EscalationEvent` by id; nil when missing."
  @spec get(binary()) :: EscalationEvent.t() | nil
  def get(id) when is_binary(id), do: Repo.get(EscalationEvent, id)
  def get(_), do: nil

  defp normalize_attrs(attrs) do
    attrs
    |> stringify_to_atom_keys()
    |> Map.update(:sender_identity, nil, &maybe_hash_phone/1)
  end

  defp maybe_hash_phone(nil), do: nil
  defp maybe_hash_phone(""), do: nil

  defp maybe_hash_phone(value) when is_binary(value) do
    if Regex.match?(@phone_pattern, value), do: ToolAudit.hash_pii(value), else: value
  end

  defp maybe_hash_phone(_), do: nil

  defp stringify_to_atom_keys(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
    end)
  rescue
    ArgumentError -> attrs
  end
end
