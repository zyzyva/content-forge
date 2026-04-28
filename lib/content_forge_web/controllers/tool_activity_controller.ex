defmodule ContentForgeWeb.ToolActivityController do
  @moduledoc """
  Phase 16.5 REST surface for the unified tool-invocation audit.

  Mirrors the LiveView `/dashboard/tool-activity` page so an
  external consumer can pull the same audit rows over HTTP. Auth
  is the standard `:api_auth` bearer-token pipeline.

  Route: `GET /api/v1/products/:product_id/tool-activity`
  """

  use ContentForgeWeb, :controller

  alias ContentForge.Products
  alias ContentForge.ToolAudit
  alias ContentForge.ToolAudit.ToolInvocationEvent

  action_fallback ContentForgeWeb.FallbackController

  @max_limit 200
  @default_limit 50

  def index(conn, %{"product_id" => product_id} = params) do
    case Products.get_product(product_id) do
      nil ->
        {:error, :not_found}

      product ->
        opts = build_opts(params)
        events = ToolAudit.list_for_product(product.id, opts)

        render(conn, :index,
          events: events,
          product: product,
          filters: extract_filters(opts)
        )
    end
  end

  defp build_opts(params) do
    [
      tool: Map.get(params, "tool"),
      channel: Map.get(params, "channel"),
      status: Map.get(params, "status"),
      limit: clamp_limit(Map.get(params, "limit"))
    ]
  end

  defp extract_filters(opts) do
    %{
      tool: Keyword.get(opts, :tool),
      channel: Keyword.get(opts, :channel),
      status: Keyword.get(opts, :status),
      limit: Keyword.get(opts, :limit)
    }
  end

  defp clamp_limit(nil), do: @default_limit
  defp clamp_limit(""), do: @default_limit

  defp clamp_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> clamp_limit(n)
      :error -> @default_limit
    end
  end

  defp clamp_limit(value) when is_integer(value) and value > 0,
    do: min(value, @max_limit)

  defp clamp_limit(_), do: @default_limit

  @doc false
  def serialize_event(%ToolInvocationEvent{} = event) do
    %{
      id: event.id,
      tool_name: event.tool_name,
      channel: event.channel,
      sender_identity: event.sender_identity,
      params: event.params,
      result_status: event.result_status,
      result_summary: event.result_summary,
      duration_ms: event.duration_ms,
      invoked_at: event.invoked_at
    }
  end
end
