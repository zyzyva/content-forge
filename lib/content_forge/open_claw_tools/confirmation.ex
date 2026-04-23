defmodule ContentForge.OpenClawTools.Confirmation do
  @moduledoc """
  Shared two-turn confirmation helper every heavy-write tool
  (16.4+) calls through. The heavy-write tools never touch
  `PendingConfirmation` directly; they call `request/4` on the
  first turn and `confirm/4` on the second.

  Contract:

    * `request(tool_name, ctx, params, preview)` generates (or
      reuses) a pending row and returns `{:ok, %{echo_phrase,
      expires_at, preview}}`. The ask is idempotent: a second
      request with the same `(session_id, tool_name,
      params_hash)` while the original row is still live (not
      consumed, not expired) returns the existing phrase rather
      than minting a new one. The `params_hash` ignores the
      reserved `"confirm"` param so an agent retry carrying the
      echo phrase stays idempotent.
    * `confirm(tool_name, ctx, params, echo_phrase)` resolves
      the pending row by `(session_id, echo_phrase)` and either
      consumes it (atomic update guarded by `consumed_at IS
      NULL`) returning `:ok`, or returns a classified error
      (`:confirmation_not_found` / `:confirmation_mismatch` /
      `:confirmation_expired`).

  Wordlist: `priv/open_claw_tools/confirmation_words.txt`
  holds three blank-line-separated buckets (colors, nouns,
  places). A phrase is `<color>-<noun>-<place>`, chosen with
  `:crypto.strong_rand_bytes/1`. Collisions (the partial
  unique index on live rows trips) retry once; a second
  collision is treated as the :confirmation_insert_failed
  failure mode and surfaces to the tool.
  """

  import Ecto.Query

  alias ContentForge.OpenClawTools.PendingConfirmation
  alias ContentForge.Repo

  @default_expiry_seconds 300

  @wordlist_path Application.app_dir(
                   :content_forge,
                   "priv/open_claw_tools/confirmation_words.txt"
                 )
  @external_resource @wordlist_path

  # Load the three buckets at compile time so the module attribute
  # carries plain lists. Keeps runtime allocation-free.
  @buckets (fn ->
              @wordlist_path
              |> File.read!()
              |> String.split(~r/\r?\n\r?\n/, trim: true)
              |> Enum.map(fn block ->
                block
                |> String.split(~r/\r?\n/, trim: true)
                |> Enum.map(&String.trim/1)
                |> Enum.reject(&(&1 == ""))
              end)
            end).()

  @max_insert_retries 1

  @type envelope :: %{
          echo_phrase: String.t(),
          expires_at: DateTime.t(),
          preview: map()
        }

  @type request_error :: :missing_session | :confirmation_insert_failed
  @type confirm_error ::
          :missing_session
          | :confirmation_not_found
          | :confirmation_mismatch
          | :confirmation_expired

  # --- public API ----------------------------------------------------------

  @spec request(String.t(), map(), map(), map()) ::
          {:ok, envelope()} | {:error, request_error()}
  def request(tool_name, ctx, params, preview)
      when is_binary(tool_name) and is_map(ctx) and is_map(params) and is_map(preview) do
    with {:ok, session_id} <- fetch_session(ctx) do
      params_hash = hash_params(params)
      now = DateTime.utc_now()

      case find_live(session_id, tool_name, params_hash, now) do
        %PendingConfirmation{} = row ->
          {:ok, envelope_from_row(row)}

        nil ->
          insert_with_retry(session_id, tool_name, params_hash, preview, now, @max_insert_retries)
      end
    end
  end

  @spec confirm(String.t(), map(), map(), String.t()) :: :ok | {:error, confirm_error()}
  def confirm(tool_name, ctx, params, echo_phrase)
      when is_binary(tool_name) and is_map(ctx) and is_map(params) and is_binary(echo_phrase) do
    with {:ok, session_id} <- fetch_session(ctx) do
      params_hash = hash_params(params)
      now = DateTime.utc_now()

      resolve(session_id, echo_phrase)
      |> classify(tool_name, params_hash, now)
      |> maybe_consume(now)
    end
  end

  # --- helpers: session + hashing ------------------------------------------

  defp fetch_session(%{session_id: value}) when is_binary(value) and value != "",
    do: {:ok, value}

  defp fetch_session(_ctx), do: {:error, :missing_session}

  # :erlang.term_to_binary/2 with :deterministic normalizes map
  # key ordering so two equal maps with different insertion order
  # hash to the same digest. Jason would require hand-rolled
  # canonical ordering for the same guarantee.
  defp hash_params(params) do
    params
    |> Map.delete("confirm")
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # --- helpers: lookup ------------------------------------------------------

  defp find_live(session_id, tool_name, params_hash, now) do
    Repo.one(
      from(p in PendingConfirmation,
        where:
          p.session_id == ^session_id and
            p.tool_name == ^tool_name and
            p.params_hash == ^params_hash and
            is_nil(p.consumed_at) and
            p.expires_at > ^now,
        order_by: [desc: p.inserted_at],
        limit: 1
      )
    )
  end

  defp resolve(session_id, echo_phrase) do
    Repo.one(
      from(p in PendingConfirmation,
        where:
          p.session_id == ^session_id and
            p.echo_phrase == ^echo_phrase and
            is_nil(p.consumed_at),
        limit: 1
      )
    )
  end

  # --- helpers: classify + consume -----------------------------------------

  defp classify(nil, _tool_name, _params_hash, _now), do: {:error, :confirmation_not_found}

  defp classify(%PendingConfirmation{tool_name: t}, tool_name, _params_hash, _now)
       when t != tool_name,
       do: {:error, :confirmation_mismatch}

  defp classify(%PendingConfirmation{params_hash: h}, _tool_name, params_hash, _now)
       when h != params_hash,
       do: {:error, :confirmation_mismatch}

  defp classify(%PendingConfirmation{expires_at: expires} = row, _tool_name, _params_hash, now) do
    case DateTime.compare(expires, now) do
      :gt -> {:ok, row}
      _ -> {:error, :confirmation_expired}
    end
  end

  defp maybe_consume({:ok, %PendingConfirmation{id: id}}, now) do
    {count, _} =
      from(p in PendingConfirmation,
        where: p.id == ^id and is_nil(p.consumed_at)
      )
      |> Repo.update_all(set: [consumed_at: now])

    if count == 1 do
      :ok
    else
      # Lost the race to a concurrent confirm. Fail safely.
      {:error, :confirmation_not_found}
    end
  end

  defp maybe_consume({:error, _} = err, _now), do: err

  # --- helpers: insert + phrase --------------------------------------------

  defp insert_with_retry(_, _, _, _, _, retries_left) when retries_left < 0,
    do: {:error, :confirmation_insert_failed}

  defp insert_with_retry(session_id, tool_name, params_hash, preview, now, retries_left) do
    phrase = random_phrase()
    expires_at = DateTime.add(now, expiry_seconds(), :second)

    attrs = %{
      session_id: session_id,
      tool_name: tool_name,
      params_hash: params_hash,
      echo_phrase: phrase,
      preview: preview,
      expires_at: expires_at
    }

    %PendingConfirmation{}
    |> PendingConfirmation.insert_changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, row} ->
        {:ok, envelope_from_row(row)}

      {:error, _changeset} ->
        insert_with_retry(session_id, tool_name, params_hash, preview, now, retries_left - 1)
    end
  end

  defp envelope_from_row(%PendingConfirmation{} = row) do
    %{
      echo_phrase: row.echo_phrase,
      expires_at: row.expires_at,
      preview: normalize_preview(row.preview)
    }
  end

  # Preview is returned to the tool (which may have just constructed
  # it as an atom-keyed map) untouched on the happy insert path, and
  # as a string-keyed map when loaded from the DB (JSONB). Normalize
  # to atom keys if possible so the tool's serializer does not have
  # to care whether the map came from the first-turn construction
  # or a reload.
  defp normalize_preview(%{} = preview) do
    Map.new(preview, fn
      {k, v} when is_binary(k) ->
        {safe_atom(k), v}

      {k, v} ->
        {k, v}
    end)
  end

  # Only convert keys we have explicitly seen the tool side put in
  # the map. Falling back to the string key is fine for unknown keys
  # rather than inflating the atom table.
  @known_preview_keys ~w(
    summary
    draft_id
    platform
    content_type
    angle
    snippet
    publish_gate
    required_override
    override_reason_present
    product_id
    before
    after
    cadence_days
    enabled
    bundle_id
    asset_count
    estimated_cost_cents
    remaining_budget_cents
    would_exceed_budget
    warning
  )a

  defp safe_atom(key) do
    atom = Enum.find(@known_preview_keys, fn a -> Atom.to_string(a) == key end)
    atom || key
  end

  defp random_phrase, do: Enum.map_join(@buckets, "-", &pick/1)

  defp pick(words) do
    idx = :crypto.strong_rand_bytes(4) |> :binary.decode_unsigned() |> rem(length(words))
    Enum.at(words, idx)
  end

  defp expiry_seconds do
    :content_forge
    |> Application.get_env(:open_claw_tools, [])
    |> Keyword.get(:confirmation_expiry_seconds, @default_expiry_seconds)
  end
end
