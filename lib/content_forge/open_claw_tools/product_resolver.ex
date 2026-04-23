defmodule ContentForge.OpenClawTools.ProductResolver do
  @moduledoc """
  Feature 13's shared product-resolution contract.

  Every OpenClaw tool that operates on a product delegates here so
  the three resolution paths (explicit UUID, explicit fuzzy name,
  SMS session-derived) live in exactly one place.

  Returns:

    * `{:ok, %Product{}}` — resolved.
    * `{:error, :product_not_found}` — the caller passed a
      `"product"` hint but no row matches.
    * `{:error, :ambiguous_product}` — the caller passed a name that
      matches more than one active product.
    * `{:error, :missing_product_context}` — the caller did not pass
      `"product"` and the channel context (SMS sender identity) did
      not yield a single active product either.

  Resolution order:

    1. If `params["product"]` is a non-empty binary, try it as a
       UUID first (via `Products.get_product/1`); on cast failure or
       missing row, fall back to a case-insensitive substring match
       across `Products.list_products/0`.
    2. If the caller did not pass a `"product"` param and the
       channel is `"sms"` with a usable `sender_identity`, look up
       the matching active `%ProductPhone{}` rows. A single match
       resolves to that product; zero or multiple match yields
       `:missing_product_context`.
    3. Otherwise, `:missing_product_context`.
  """

  alias ContentForge.Products
  alias ContentForge.Products.Product
  alias ContentForge.Sms

  @type ctx :: %{
          optional(:session_id) => String.t() | nil,
          optional(:channel) => String.t() | nil,
          optional(:sender_identity) => String.t() | nil
        }

  @type resolve_error ::
          :product_not_found | :ambiguous_product | :missing_product_context

  @spec resolve(ctx(), map()) :: {:ok, Product.t()} | {:error, resolve_error()}
  def resolve(ctx, params) when is_map(params) do
    resolve_with_param(ctx, Map.get(params, "product"))
  end

  # --- explicit product param -----------------------------------------------

  defp resolve_with_param(ctx, nil), do: resolve_from_session(ctx)
  defp resolve_with_param(ctx, ""), do: resolve_from_session(ctx)

  defp resolve_with_param(_ctx, id_or_name) when is_binary(id_or_name) do
    case get_product_by_id(id_or_name) do
      %Product{} = product -> {:ok, product}
      nil -> resolve_by_name(id_or_name)
    end
  end

  defp get_product_by_id(id_or_name) do
    Products.get_product(id_or_name)
  rescue
    Ecto.Query.CastError -> nil
  end

  defp resolve_by_name(name) do
    case fuzzy_match(name) do
      [product] -> {:ok, product}
      [] -> {:error, :product_not_found}
      [_ | _] -> {:error, :ambiguous_product}
    end
  end

  defp fuzzy_match(needle) do
    lowered = String.downcase(needle)

    Products.list_products()
    |> Enum.filter(fn %Product{name: name} ->
      String.contains?(String.downcase(name), lowered)
    end)
  end

  # --- session-derived resolution ------------------------------------------

  defp resolve_from_session(%{channel: "sms", sender_identity: phone})
       when is_binary(phone) and phone != "" do
    case Sms.list_active_phones_by_number(phone) do
      [%{product_id: product_id}] -> load_product(product_id)
      _other -> {:error, :missing_product_context}
    end
  end

  defp resolve_from_session(_ctx), do: {:error, :missing_product_context}

  defp load_product(product_id) do
    case Products.get_product(product_id) do
      %Product{} = product -> {:ok, product}
      nil -> {:error, :missing_product_context}
    end
  end
end
