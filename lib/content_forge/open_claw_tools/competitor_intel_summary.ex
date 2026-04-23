defmodule ContentForge.OpenClawTools.CompetitorIntelSummary do
  @moduledoc """
  OpenClaw tool: returns the most recent `CompetitorIntel` record
  for the resolved product so the agent can answer "what are
  competitors doing?".

  Reuses `Products.get_latest_competitor_intel_for_product/1`.
  Returning `:not_found` when no intel row exists is deliberate:
  the bot should say "I do not have competitor data for <product>
  yet" rather than imply an empty competitive landscape.

  Params:

    * `"product"` - optional, resolved via `ProductResolver`.

  Result fields: `product_id, product_name, generated_at, summary,
  trending_topics, winning_formats, effective_hooks,
  source_post_count`.

  Errors: `:missing_product_context`, `:product_not_found`,
  `:ambiguous_product`, `:not_found`.
  """

  alias ContentForge.OpenClawTools.ProductResolver
  alias ContentForge.Products
  alias ContentForge.Products.CompetitorIntel

  @spec call(map(), map()) :: {:ok, map()} | {:error, term()}
  def call(ctx, params) when is_map(params) do
    with {:ok, product} <- ProductResolver.resolve(ctx, params),
         %CompetitorIntel{} = intel <-
           Products.get_latest_competitor_intel_for_product(product.id) do
      {:ok,
       %{
         product_id: product.id,
         product_name: product.name,
         generated_at: iso8601(intel.inserted_at),
         summary: intel.summary,
         trending_topics: intel.trending_topics || [],
         winning_formats: intel.winning_formats || [],
         effective_hooks: intel.effective_hooks || [],
         source_post_count: intel.source_count
       }}
    else
      nil -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp iso8601(%NaiveDateTime{} = ndt) do
    ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
  end
end
