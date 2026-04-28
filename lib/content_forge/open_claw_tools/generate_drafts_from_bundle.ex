defmodule ContentForge.OpenClawTools.GenerateDraftsFromBundle do
  @moduledoc """
  OpenClaw tool: kicks off bundle-driven draft generation behind
  the 16.4 two-turn confirmation envelope. First turn surfaces
  the estimated cost and the remaining generation budget so the
  agent can read both to the user before asking for the echo
  phrase; second turn enqueues
  `ContentForge.Jobs.AssetBundleDraftGenerator`.

  Budget is transparency-only in this slice: a request that
  would exceed the configured ceiling still enqueues, with a
  `warning` string in the preview the agent is expected to pass
  on verbatim. The Oban worker's own cost ceiling remains the
  authoritative hard stop.

  Authorization: requires `:owner` on the resolved product.

  Params (required):

    * `"bundle_id"` - exact UUID of a bundle owned by the
      resolved product. Cross-product / unknown / malformed ids
      collapse to `:not_found` uniformly.

  Params (optional):

    * `"product"` - resolved via `ProductResolver`.
    * `"platforms"` - list of platform strings. Defaults to the
      `ContentForge.Metrics.GenerationBudget.default_platforms/0`
      list (`["twitter", "linkedin"]` unless overridden in config).
    * `"variants_per_platform"` - integer > 0. Defaults to
      `GenerationBudget.default_variants_per_platform/0` (3).
    * `"confirm"` - echo phrase from the first-turn envelope.

  Returns `{:ok, :confirmation_required, envelope}` on turn one,
  `{:ok, %{enqueued: true, ...}}` on a successful turn two, or a
  classified error.

  Errors: `:missing_product_context`, `:product_not_found`,
  `:ambiguous_product`, `:forbidden`, `:not_found`, plus the
  standard confirmation reasons.
  """

  alias ContentForge.Jobs.AssetBundleDraftGenerator
  alias ContentForge.Metrics.GenerationBudget
  alias ContentForge.OpenClawTools.Authorization
  alias ContentForge.OpenClawTools.Confirmation
  alias ContentForge.OpenClawTools.ProductResolver
  alias ContentForge.ProductAssets
  alias ContentForge.ProductAssets.AssetBundle

  @tool_name "generate_drafts_from_bundle"

  @spec call(map(), map()) ::
          {:ok, map()} | {:ok, :confirmation_required, map()} | {:error, term()}
  def call(ctx, params) when is_map(params) do
    with {:ok, product} <- ProductResolver.resolve(ctx, params),
         {:ok, bundle} <- fetch_bundle(product, params),
         :ok <- Authorization.require(Map.put(ctx, :product, product), :owner) do
      dispatch_turn(ctx, params, product, bundle)
    end
  end

  # --- turn dispatch --------------------------------------------------------

  defp dispatch_turn(ctx, params, product, bundle) do
    plan = build_plan(product, bundle, params)

    case binary_param(params, "confirm") do
      nil -> request_turn(ctx, params, plan)
      echo -> confirm_turn(ctx, params, plan, echo)
    end
  end

  defp build_plan(product, bundle, params) do
    platforms = fetch_platforms(params)
    variants = fetch_variants(params)
    asset_count = length(bundle.bundle_assets)
    estimate = estimate(asset_count, platforms, variants)
    remaining = GenerationBudget.remaining_generation_budget(product.id)

    %{
      bundle: bundle,
      platforms: platforms,
      variants: variants,
      asset_count: asset_count,
      estimate: estimate,
      remaining: remaining,
      would_exceed: estimate > remaining
    }
  end

  defp request_turn(ctx, params, plan) do
    preview = build_preview(plan)

    case Confirmation.request(@tool_name, ctx, params, preview) do
      {:ok, envelope} -> {:ok, :confirmation_required, envelope}
      {:error, _} = err -> err
    end
  end

  defp confirm_turn(ctx, params, plan, echo) do
    with :ok <- Confirmation.confirm(@tool_name, ctx, params, echo) do
      job_args = build_job_args(plan.bundle, plan.platforms, plan.variants)

      case job_args |> AssetBundleDraftGenerator.new() |> Oban.insert() do
        {:ok, _job} ->
          {:ok,
           %{
             enqueued: true,
             bundle_id: plan.bundle.id,
             estimated_cost_cents: plan.estimate,
             remaining_budget_cents: plan.remaining,
             job_args: job_args
           }}

        {:error, _reason} ->
          {:error, :enqueue_failed}
      end
    end
  end

  # --- preview --------------------------------------------------------------

  defp build_preview(%{bundle: bundle} = plan) do
    preview = %{
      summary:
        "Generate #{plan.variants} variants per platform for bundle '#{bundle.name}' " <>
          "(#{plan.asset_count} asset(s) across #{length(plan.platforms)} platform(s)).",
      bundle_id: bundle.id,
      asset_count: plan.asset_count,
      platforms: plan.platforms,
      variants_per_platform: plan.variants,
      estimated_cost_cents: plan.estimate,
      remaining_budget_cents: plan.remaining,
      would_exceed_budget: plan.would_exceed
    }

    if plan.would_exceed do
      Map.put(
        preview,
        :warning,
        "Estimated cost (#{plan.estimate} cents) exceeds the remaining generation budget " <>
          "(#{plan.remaining} cents). The job will still be enqueued if you confirm."
      )
    else
      preview
    end
  end

  # --- cost estimation ------------------------------------------------------

  defp estimate(asset_count, platforms, variants) do
    GenerationBudget.estimate_generation_cost(
      asset_count: asset_count,
      platform_count: length(platforms),
      variants_per_platform: variants
    )
  end

  # --- param helpers --------------------------------------------------------

  defp fetch_platforms(params) do
    case Map.get(params, "platforms") do
      list when is_list(list) and list != [] ->
        list
        |> Enum.filter(&(is_binary(&1) and &1 != ""))

      _ ->
        GenerationBudget.default_platforms()
    end
  end

  defp fetch_variants(params) do
    case Map.get(params, "variants_per_platform") do
      n when is_integer(n) and n > 0 -> n
      _ -> GenerationBudget.default_variants_per_platform()
    end
  end

  defp build_job_args(bundle, platforms, variants) do
    %{
      "bundle_id" => bundle.id,
      "platforms" => platforms,
      "variants_per_platform" => variants
    }
  end

  defp binary_param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  # --- bundle lookup --------------------------------------------------------

  defp fetch_bundle(product, params) do
    case binary_param(params, "bundle_id") do
      nil -> {:error, :not_found}
      id -> scoped_bundle(product, id)
    end
  end

  defp scoped_bundle(product, id) do
    case safe_get_bundle(id) do
      %AssetBundle{product_id: pid} = bundle when pid == product.id -> {:ok, bundle}
      _ -> {:error, :not_found}
    end
  end

  defp safe_get_bundle(id) do
    ProductAssets.get_bundle(id)
  rescue
    Ecto.Query.CastError -> nil
  end
end
