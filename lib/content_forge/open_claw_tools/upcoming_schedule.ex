defmodule ContentForge.OpenClawTools.UpcomingSchedule do
  @moduledoc """
  OpenClaw tool: lists approved drafts awaiting publish for the
  resolved product so the agent can answer "what is going out this
  week?".

  Content Forge does not currently hold per-draft `scheduled_at`
  timestamps, so the tool reflects the dashboard's "approved and
  queued" semantics (reusing
  `ContentGeneration.list_approved_drafts/1`) rather than inventing
  schedule times. The agent description in the Node plugin tells
  the model to speak in terms of "queued" rather than "scheduled
  for Thursday at 10am."

  Params:

    * `"product"` - optional, resolved via `ProductResolver`.
    * `"limit"` - optional integer, default 10, clamped to
      `[1, 25]`.
    * `"platform"` - optional filter on the draft's `platform`
      field.

  Result: `%{product_id, product_name, count, drafts: [...]}`.
  Each draft carries `id, platform, content_type, angle, snippet,
  approved_at, status`. An empty approved list returns `count: 0`
  (not an error).

  Errors: `:missing_product_context`, `:product_not_found`,
  `:ambiguous_product`.
  """

  alias ContentForge.ContentGeneration
  alias ContentForge.OpenClawTools.ProductResolver

  @default_limit 10
  @limit_min 1
  @limit_max 25
  @snippet_length 200

  @spec call(map(), map()) :: {:ok, map()} | {:error, term()}
  def call(ctx, params) when is_map(params) do
    with {:ok, product} <- ProductResolver.resolve(ctx, params) do
      platform = non_empty_binary(Map.get(params, "platform"))
      limit = fetch_limit(params)

      drafts =
        product.id
        |> ContentGeneration.list_approved_drafts()
        |> filter_platform(platform)
        |> Enum.take(limit)

      {:ok,
       %{
         product_id: product.id,
         product_name: product.name,
         count: length(drafts),
         drafts: Enum.map(drafts, &serialize_draft/1)
       }}
    end
  end

  defp filter_platform(drafts, nil), do: drafts

  defp filter_platform(drafts, platform),
    do: Enum.filter(drafts, &(&1.platform == platform))

  defp non_empty_binary(value) when is_binary(value) and value != "", do: value
  defp non_empty_binary(_), do: nil

  defp fetch_limit(params) do
    params
    |> Map.get("limit", @default_limit)
    |> clamp_limit()
  end

  defp clamp_limit(value) when is_integer(value) do
    value |> max(@limit_min) |> min(@limit_max)
  end

  defp clamp_limit(_), do: @default_limit

  defp serialize_draft(draft) do
    %{
      id: draft.id,
      platform: draft.platform,
      content_type: draft.content_type,
      angle: draft.angle,
      snippet: snippet(draft.content),
      approved_at: iso8601(draft.updated_at),
      status: draft.status
    }
  end

  defp snippet(nil), do: ""
  defp snippet(text), do: text |> to_string() |> String.slice(0, @snippet_length)

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp iso8601(%NaiveDateTime{} = ndt) do
    ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
  end
end
