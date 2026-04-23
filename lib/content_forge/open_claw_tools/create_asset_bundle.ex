defmodule ContentForge.OpenClawTools.CreateAssetBundle do
  @moduledoc """
  OpenClaw tool: creates a named `AssetBundle` for the resolved
  product so the agent can group assets before kicking off
  bundle-driven draft generation (16.4 `generate_drafts_from_bundle`
  picks these up).

  Authorization: requires `:submitter` or higher on the resolved
  product.

  Params (required):

    * `"name"` - bundle name (1..120 chars after trimming).

  Params (optional):

    * `"context"` - free-text context the agent lifted from the
      user's message (e.g. "Johnson family kitchen remodel, 3
      weeks, quartz counters"). Passed through verbatim.
    * `"product"` - resolved via `ProductResolver`; SMS callers
      can omit this once a phone is registered.

  Returns `{:ok, %{bundle_id, product_id, product_name, name,
  status, created_at}}` on success.

  Errors: `:missing_product_context`, `:product_not_found`,
  `:ambiguous_product`, `:forbidden`, `:invalid_name`,
  `{:invalid_params, errors}` (for changeset errors outside the
  name path).
  """

  alias ContentForge.OpenClawTools.Authorization
  alias ContentForge.OpenClawTools.ProductResolver
  alias ContentForge.ProductAssets

  @name_min 1
  @name_max 120

  @spec call(map(), map()) :: {:ok, map()} | {:error, term()}
  def call(ctx, params) when is_map(params) do
    with {:ok, product} <- ProductResolver.resolve(ctx, params),
         :ok <- Authorization.require(Map.put(ctx, :product, product), :submitter),
         {:ok, name} <- fetch_name(params),
         {:ok, bundle} <- insert_bundle(product, name, Map.get(params, "context")) do
      {:ok,
       %{
         bundle_id: bundle.id,
         product_id: product.id,
         product_name: product.name,
         name: bundle.name,
         status: bundle.status,
         created_at: DateTime.to_iso8601(bundle.inserted_at)
       }}
    end
  end

  defp fetch_name(params) do
    case params |> Map.get("name", "") |> to_trimmed_string() do
      "" -> {:error, :invalid_name}
      name when byte_size(name) > @name_max -> {:error, :invalid_name}
      name when byte_size(name) < @name_min -> {:error, :invalid_name}
      name -> {:ok, name}
    end
  end

  defp to_trimmed_string(value) when is_binary(value), do: String.trim(value)
  defp to_trimmed_string(_), do: ""

  defp insert_bundle(product, name, context) do
    attrs = %{product_id: product.id, name: name, context: context}

    case ProductAssets.create_bundle(attrs) do
      {:ok, bundle} -> {:ok, bundle}
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
