defmodule ContentForge.OpenClawTools.RecordMemory do
  @moduledoc """
  OpenClaw tool: persists a conversation-derived note against
  the resolved product so future conversations can recall
  context the user shared (a client preference, a seasonal
  pattern, a past job).

  Authorization: requires `:submitter` or higher on the resolved
  product.

  Params (required):

    * `"content"` - free text, 1..2000 characters after trimming.

  Params (optional):

    * `"tags"` - list of strings (each 1..40 chars). The tool
      trims + lowercases + dedupes before persisting so
      `"Spring"` and `"spring"` end up as one tag.
    * `"product"` - resolved via `ProductResolver`; SMS callers
      can omit once a phone is registered.

  `session_id`, `channel`, and `sender_identity` come from the
  invocation ctx, not from params. The agent cannot spoof these
  fields through the tool surface.

  Returns `{:ok, %{memory_id, product_id, session_id,
  recorded_at}}` on success.

  Errors: `:missing_product_context`, `:product_not_found`,
  `:ambiguous_product`, `:forbidden`, `:empty_content`,
  `:content_too_long`, `:invalid_tag`, `:missing_session`,
  `{:invalid_params, errors}` (for changeset errors outside
  the content / tag paths).
  """

  alias ContentForge.OpenClawTools.Authorization
  alias ContentForge.OpenClawTools.ProductResolver
  alias ContentForge.Products

  @content_max 2000
  @tag_min 1
  @tag_max 40

  @spec call(map(), map()) :: {:ok, map()} | {:error, term()}
  def call(ctx, params) when is_map(params) do
    with {:ok, product} <- ProductResolver.resolve(ctx, params),
         :ok <- Authorization.require(Map.put(ctx, :product, product), :submitter),
         {:ok, content} <- fetch_content(params),
         {:ok, tags} <- fetch_tags(params),
         {:ok, session_id} <- fetch_session(ctx),
         {:ok, memory} <- insert_memory(product, ctx, session_id, content, tags) do
      {:ok,
       %{
         memory_id: memory.id,
         product_id: product.id,
         session_id: session_id,
         recorded_at: DateTime.to_iso8601(memory.inserted_at)
       }}
    end
  end

  # --- content validation ---------------------------------------------------

  defp fetch_content(params) do
    case params |> Map.get("content", "") |> to_trimmed_string() do
      "" -> {:error, :empty_content}
      content when byte_size(content) > @content_max -> {:error, :content_too_long}
      content -> {:ok, content}
    end
  end

  defp to_trimmed_string(value) when is_binary(value), do: String.trim(value)
  defp to_trimmed_string(_), do: ""

  # --- tag validation -------------------------------------------------------

  defp fetch_tags(params) do
    case Map.get(params, "tags") do
      nil -> {:ok, []}
      list when is_list(list) -> normalize_tags(list)
      _ -> {:error, :invalid_tag}
    end
  end

  defp normalize_tags(raw_tags) do
    Enum.reduce_while(raw_tags, {:ok, []}, fn tag, {:ok, acc} ->
      case normalize_tag(tag) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, tags} -> {:ok, Enum.uniq(tags)}
      other -> other
    end
  end

  defp normalize_tag(tag) when is_binary(tag) do
    normalized = tag |> String.trim() |> String.downcase()

    cond do
      byte_size(normalized) < @tag_min -> {:error, :invalid_tag}
      byte_size(normalized) > @tag_max -> {:error, :invalid_tag}
      true -> {:ok, normalized}
    end
  end

  defp normalize_tag(_), do: {:error, :invalid_tag}

  # --- session extraction ---------------------------------------------------

  defp fetch_session(%{session_id: value}) when is_binary(value) and value != "",
    do: {:ok, value}

  defp fetch_session(_ctx), do: {:error, :missing_session}

  # --- persistence ----------------------------------------------------------

  defp insert_memory(product, ctx, session_id, content, tags) do
    attrs = %{
      product_id: product.id,
      session_id: session_id,
      channel: Map.get(ctx, :channel),
      sender_identity: Map.get(ctx, :sender_identity),
      content: content,
      tags: tags
    }

    case Products.create_memory(attrs) do
      {:ok, memory} -> {:ok, memory}
      {:error, %Ecto.Changeset{} = cs} -> {:error, {:invalid_params, changeset_errors(cs)}}
    end
  end

  defp changeset_errors(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
  end
end
