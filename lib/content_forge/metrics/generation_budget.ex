defmodule ContentForge.Metrics.GenerationBudget do
  @moduledoc """
  Thin cost-estimate helper for draft-generation cost surfacing.

  Phase 16.4d needs to show the user an "estimated cost" and a
  "remaining budget" before an owner confirms a bundle-driven
  draft generation. The dashboard has no first-class cost model
  yet; this module is the minimum viable seam that the tool
  surface reads from, driven entirely by application config:

      config :content_forge, :generation_budget,
        monthly_cents: 10_000,
        cost_per_variant_cents: 5

  `estimate_generation_cost/1` multiplies the per-variant cost
  by `asset_count * platform_count * variants_per_platform` so
  a 5-asset bundle targeting two platforms with three variants
  each bills at `5 * 2 * 3 * 5 = 150` cents. When config is
  missing, the estimate falls back to a single platform + single
  variant so the agent still has a concrete number to read.

  `remaining_generation_budget/1` currently returns the entire
  `monthly_cents` ceiling regardless of `product_id`. Consumption
  tracking is not in scope for this slice; a real accounting
  ledger lands alongside Phase 16.5's unified tool-invocation
  audit. Until then, `would_exceed_budget` in the tool preview
  is always `false` unless the single-shot estimate itself
  exceeds the configured ceiling, which mirrors the spec's
  transparency-not-enforcement stance.
  """

  @default_cost_per_variant_cents 5
  @default_monthly_cents 10_000
  @default_platforms ~w(twitter linkedin)
  @default_variants_per_platform 3

  @doc """
  Estimates the generation cost in cents for a bundle-driven
  job. Accepts a keyword list so the caller is explicit about
  which axes drive the cost:

    * `:asset_count` - number of assets in the bundle (required).
    * `:platform_count` - number of target platforms (default 2).
    * `:variants_per_platform` - variants per platform (default 3).
  """
  @spec estimate_generation_cost(keyword()) :: non_neg_integer()
  def estimate_generation_cost(opts) when is_list(opts) do
    asset_count = Keyword.get(opts, :asset_count, 0)

    platform_count =
      Keyword.get(opts, :platform_count, length(default_platforms()))

    variants = Keyword.get(opts, :variants_per_platform, default_variants_per_platform())

    asset_count * platform_count * variants * cost_per_variant_cents()
  end

  @doc """
  Returns the remaining generation budget in cents for a
  product. Until an accounting ledger lands, this is a static
  ceiling sourced from config; every product shares the same
  allowance. Returning it as a function rather than a constant
  so callers pass a `product_id` that later slices can honor
  without breaking the signature.
  """
  @spec remaining_generation_budget(Ecto.UUID.t()) :: non_neg_integer()
  def remaining_generation_budget(product_id) when is_binary(product_id) do
    monthly_cents()
  end

  @doc "Default target platforms when the tool caller does not supply a list."
  @spec default_platforms() :: [String.t()]
  def default_platforms do
    config()
    |> Keyword.get(:default_platforms, @default_platforms)
  end

  @doc "Default variants-per-platform when the tool caller omits it."
  @spec default_variants_per_platform() :: pos_integer()
  def default_variants_per_platform do
    config()
    |> Keyword.get(:default_variants_per_platform, @default_variants_per_platform)
  end

  defp cost_per_variant_cents do
    config()
    |> Keyword.get(:cost_per_variant_cents, @default_cost_per_variant_cents)
  end

  defp monthly_cents do
    config()
    |> Keyword.get(:monthly_cents, @default_monthly_cents)
  end

  defp config, do: Application.get_env(:content_forge, :generation_budget, [])
end
