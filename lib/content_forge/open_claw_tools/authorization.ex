defmodule ContentForge.OpenClawTools.Authorization do
  @moduledoc """
  Role gate for OpenClaw tools.

  Every light-write (16.3+) and heavy-write (16.4) tool calls
  `require(ctx, required_role)` as the first step of its
  `call/2`. The helper resolves the caller's role through the
  channel-specific lookup, compares it against the strict
  `:owner > :submitter > :viewer` hierarchy, and returns `:ok` on
  success or `{:error, :forbidden}`.

  Resolution rules:

    * `ctx.channel == "sms"` looks up
      `(sender_identity, product.id)` in `ProductPhone`; active
      rows yield the string `role` from the row.
    * Any other channel looks up
      `(sender_identity, product.id)` in `OperatorIdentity` via
      `ContentForge.Operators.lookup_active_identity/2`.
    * Missing ctx fields (`channel`, `sender_identity`,
      `product`), empty sender, unknown channels, inactive rows,
      rows registered under another product, and unknown required
      roles all collapse to `{:error, :forbidden}` with zero DB
      I/O where possible.

  Failures are never distinguishable in the returned reason.
  The controller maps `:forbidden` to a uniform 422 response so
  a probing caller cannot infer which path denied them.
  """

  alias ContentForge.Operators
  alias ContentForge.Products.Product
  alias ContentForge.Sms

  @type role :: :owner | :submitter | :viewer
  @type ctx :: %{
          optional(:channel) => String.t() | nil,
          optional(:sender_identity) => String.t() | nil,
          optional(:product) => Product.t() | nil
        }

  # :owner >= :submitter >= :viewer. A higher-ranked role
  # satisfies any requirement at or below its rank.
  @ranks %{owner: 3, submitter: 2, viewer: 1}

  @spec require(ctx(), role()) :: :ok | {:error, :forbidden}
  def require(ctx, required_role) when is_map(ctx) do
    with {:ok, required_rank} <- rank_of(required_role),
         {:ok, channel} <- extract_binary(ctx, :channel),
         {:ok, sender} <- extract_binary(ctx, :sender_identity),
         %Product{id: product_id} <- Map.get(ctx, :product) || :no_product,
         {:ok, role} <- resolve(channel, sender, product_id),
         {:ok, role_rank} <- rank_of(role) do
      if role_rank >= required_rank do
        :ok
      else
        {:error, :forbidden}
      end
    else
      _ -> {:error, :forbidden}
    end
  end

  def require(_ctx, _role), do: {:error, :forbidden}

  # --- resolvers ------------------------------------------------------------

  defp resolve("sms", sender, product_id) do
    case Sms.lookup_phone(sender, product_id) do
      %{role: role, active: true} when is_binary(role) -> {:ok, role}
      _ -> :forbidden
    end
  end

  defp resolve("cli", sender, product_id), do: resolve_operator(sender, product_id)
  defp resolve(nil, _sender, _product_id), do: :forbidden
  defp resolve(_unknown_channel, _sender, _product_id), do: :forbidden

  defp resolve_operator(sender, product_id) do
    case Operators.lookup_active_identity(sender, product_id) do
      %{role: role} when is_binary(role) -> {:ok, role}
      _ -> :forbidden
    end
  end

  # --- helpers --------------------------------------------------------------

  defp extract_binary(ctx, key) do
    case Map.get(ctx, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> :invalid
    end
  end

  defp rank_of(value) when is_atom(value) do
    case Map.fetch(@ranks, value) do
      {:ok, rank} -> {:ok, rank}
      :error -> :invalid
    end
  end

  defp rank_of(value) when is_binary(value) do
    case value do
      "owner" -> {:ok, 3}
      "submitter" -> {:ok, 2}
      "viewer" -> {:ok, 1}
      _ -> :invalid
    end
  end

  defp rank_of(_), do: :invalid
end
