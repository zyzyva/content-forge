defmodule ContentForge.ToolAudit do
  @moduledoc """
  Phase 16.5 unified tool-invocation audit.

  Centralizes the audit row writer + the read API the LiveView
  dashboard and REST surface use. Tool dispatchers
  (`ContentForge.OpenClawTools.dispatch/3` and the MCP server's
  `handle_tool_call/2`) call `log_invocation/5` once per tool
  call; everything else - PII redaction, result classification,
  product-id extraction - happens here so the per-tool modules
  stay clean.

  ## PII redaction

  Two redaction rules:

    1. `sender_identity` - hashed when it looks like an E.164
       phone number (`+\d+`). Non-phone identities (`"cli:ops"`,
       `"mcp"`) pass through unchanged because they are not PII.
    2. Tool params - keys listed in
       `:default_pii_keys` plus any per-tool override in the
       `:tool_audit, :pii_keys_per_tool` config map have their
       values replaced with their SHA-256 hash.

  Hashes are prefixed with `"sha256:"` so a future maintainer can
  tell at a glance the column does not contain plaintext.
  """

  import Ecto.Query

  alias ContentForge.Repo
  alias ContentForge.ToolAudit.ToolInvocationEvent

  @default_pii_keys ~w(phone_number phone email sender_identity)

  @doc """
  Writes an audit row for a single tool invocation.

  `meta` carries optional pre-computed values:

    * `:duration_ms` - timing recorded by the dispatcher.
    * `:product_id` - explicit product binding (used when the
      caller already resolved a product the result envelope
      cannot surface, e.g. error rows).
    * `:invoked_at` - override the timestamp; defaults to now.
  """
  @spec log_invocation(String.t(), map(), map(), term(), map()) ::
          {:ok, ToolInvocationEvent.t()} | {:error, Ecto.Changeset.t()}
  def log_invocation(tool_name, ctx, params, result, meta \\ %{})
      when is_binary(tool_name) and is_map(ctx) and is_map(params) do
    {status, summary} = normalize_result(result)
    pii_keys = pii_keys_for(tool_name)
    redacted_params = redact(params, pii_keys)
    sender_identity = redact_sender_identity(Map.get(ctx, :sender_identity))
    channel = Map.get(ctx, :channel) || "unknown"
    product_id = Map.get(meta, :product_id) || extract_product_id(result, params)
    invoked_at = Map.get(meta, :invoked_at) || DateTime.utc_now()
    duration_ms = Map.get(meta, :duration_ms)

    %ToolInvocationEvent{}
    |> ToolInvocationEvent.changeset(%{
      tool_name: tool_name,
      channel: channel,
      sender_identity: sender_identity,
      params: redacted_params,
      result_status: status,
      result_summary: summary,
      duration_ms: duration_ms,
      invoked_at: invoked_at,
      product_id: product_id
    })
    |> Repo.insert()
  end

  @doc """
  Hashes an arbitrary string with SHA-256 and returns
  `"sha256:<base64>"`. Returns `nil` for nil / empty input.
  """
  @spec hash_pii(term()) :: String.t() | nil
  def hash_pii(nil), do: nil
  def hash_pii(""), do: nil

  def hash_pii(value) when is_binary(value) do
    "sha256:" <> Base.url_encode64(:crypto.hash(:sha256, value), padding: false)
  end

  def hash_pii(value), do: hash_pii(to_string(value))

  @doc """
  Returns a copy of `params` with any value at a key in
  `pii_keys` replaced by its SHA-256 hash.

  Accepts both string-keyed and atom-keyed maps; non-binary
  values pass through unchanged so the redactor never crashes
  on unexpected shapes.
  """
  @spec redact(map(), [String.t()]) :: map()
  def redact(params, pii_keys) when is_map(params) and is_list(pii_keys) do
    pii_set = MapSet.new(pii_keys)

    Map.new(params, fn {k, v} ->
      key_string = to_string(k)

      if MapSet.member?(pii_set, key_string) do
        {k, redact_value(v)}
      else
        {k, v}
      end
    end)
  end

  defp redact_value(v) when is_binary(v) and v != "", do: hash_pii(v)
  defp redact_value(v), do: v

  @doc """
  Maps a tool result tuple to `{result_status, result_summary}`.

  Knows the OpenClaw envelope (`{:ok, map}`,
  `{:ok, :confirmation_required, envelope}`, `{:error, reason}`)
  and the MCP error envelope (`{:error, %{code: code, ...}}`).
  """
  @spec normalize_result(term()) :: {String.t(), String.t() | nil}
  def normalize_result({:ok, _result}), do: {"ok", nil}

  def normalize_result({:ok, :confirmation_required, _envelope}),
    do: {"confirmation_required", nil}

  def normalize_result({:error, :unknown_tool}), do: {"unknown_tool", "unknown_tool"}
  def normalize_result({:error, atom}) when is_atom(atom), do: {"error", Atom.to_string(atom)}

  def normalize_result({:error, {tag, _details}}) when is_atom(tag),
    do: {"error", Atom.to_string(tag)}

  def normalize_result({:error, %{code: code}}) when is_binary(code), do: {"error", code}
  def normalize_result({:error, %{code: code}}) when is_atom(code), do: {"error", to_string(code)}
  def normalize_result({:error, _other}), do: {"error", "unknown_error"}

  @doc """
  Lists audit rows for a product, newest first.

  Options:

    * `:tool` - filter by tool_name
    * `:channel` - filter by channel
    * `:status` - filter by result_status
    * `:limit` - cap row count (default 100)
  """
  @spec list_for_product(binary(), keyword()) :: [ToolInvocationEvent.t()]
  def list_for_product(product_id, opts) when is_binary(product_id) do
    ToolInvocationEvent
    |> where([e], e.product_id == ^product_id)
    |> apply_filters(opts)
    |> order_by([e], desc: e.invoked_at)
    |> limit(^Keyword.get(opts, :limit, 100))
    |> Repo.all()
  end

  @doc """
  Lists audit rows across all products, newest first.

  Options match `list_for_product/2` plus an optional
  `:product_id` override for parity with the dashboard.
  """
  @spec list_recent(keyword()) :: [ToolInvocationEvent.t()]
  def list_recent(opts) do
    ToolInvocationEvent
    |> apply_filters(opts)
    |> order_by([e], desc: e.invoked_at)
    |> limit(^Keyword.get(opts, :limit, 100))
    |> Repo.all()
  end

  defp apply_filters(query, opts) do
    Enum.reduce(opts, query, fn
      {:tool, nil}, q -> q
      {:tool, ""}, q -> q
      {:tool, name}, q -> where(q, [e], e.tool_name == ^name)
      {:channel, nil}, q -> q
      {:channel, ""}, q -> q
      {:channel, ch}, q -> where(q, [e], e.channel == ^ch)
      {:status, nil}, q -> q
      {:status, ""}, q -> q
      {:status, st}, q -> where(q, [e], e.result_status == ^st)
      {:product_id, nil}, q -> q
      {:product_id, pid}, q -> where(q, [e], e.product_id == ^pid)
      {_other, _value}, q -> q
    end)
  end

  defp pii_keys_for(tool_name) do
    overrides =
      :content_forge
      |> Application.get_env(:tool_audit, [])
      |> Keyword.get(:pii_keys_per_tool, %{})
      |> Map.get(tool_name, [])

    @default_pii_keys ++ overrides
  end

  defp redact_sender_identity(nil), do: nil
  defp redact_sender_identity(""), do: nil

  defp redact_sender_identity(value) when is_binary(value) do
    if phone_number?(value), do: hash_pii(value), else: value
  end

  defp redact_sender_identity(_), do: nil

  defp phone_number?(value) when is_binary(value), do: Regex.match?(~r/^\+\d{7,15}$/, value)

  defp extract_product_id({:ok, %{product_id: id}}, _params), do: valid_uuid(id)

  defp extract_product_id({:ok, :confirmation_required, %{preview: %{product_id: id}}}, _params),
    do: valid_uuid(id)

  defp extract_product_id(_result, %{"product_id" => id}), do: valid_uuid(id)
  defp extract_product_id(_result, %{product_id: id}), do: valid_uuid(id)
  defp extract_product_id(_result, _params), do: nil

  defp valid_uuid(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp valid_uuid(_), do: nil
end
