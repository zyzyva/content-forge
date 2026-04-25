defmodule ContentForge.Metrics.GenerationBudgetTest do
  @moduledoc """
  Phase 16.4d: thin cost-estimate helper the `GenerateDraftsFromBundle`
  tool reads from. Verifies the config-driven calculations; a real
  accounting ledger is not in scope for this slice.
  """
  use ExUnit.Case, async: false

  alias ContentForge.Metrics.GenerationBudget

  setup do
    original = Application.get_env(:content_forge, :generation_budget)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:content_forge, :generation_budget)
      else
        Application.put_env(:content_forge, :generation_budget, original)
      end
    end)

    :ok
  end

  describe "estimate_generation_cost/1" do
    test "multiplies asset_count * platform_count * variants * per_variant_cost" do
      Application.put_env(:content_forge, :generation_budget, cost_per_variant_cents: 5)

      cost =
        GenerationBudget.estimate_generation_cost(
          asset_count: 4,
          platform_count: 2,
          variants_per_platform: 3
        )

      assert cost == 4 * 2 * 3 * 5
    end

    test "defaults to two platforms + three variants when unspecified" do
      Application.put_env(:content_forge, :generation_budget, cost_per_variant_cents: 5)

      cost = GenerationBudget.estimate_generation_cost(asset_count: 1)

      # 1 asset * 2 default platforms * 3 default variants * 5 cents
      assert cost == 30
    end

    test "zero assets yields zero cost" do
      assert 0 == GenerationBudget.estimate_generation_cost(asset_count: 0)
    end

    test "custom cost_per_variant_cents from config is honored" do
      Application.put_env(:content_forge, :generation_budget, cost_per_variant_cents: 20)

      # 2 assets * 2 default platforms * 3 default variants * 20 cents
      assert 240 ==
               GenerationBudget.estimate_generation_cost(asset_count: 2)
    end
  end

  describe "remaining_generation_budget/1" do
    test "returns the configured monthly ceiling" do
      Application.put_env(:content_forge, :generation_budget, monthly_cents: 50_000)

      assert 50_000 ==
               GenerationBudget.remaining_generation_budget(Ecto.UUID.generate())
    end

    test "defaults to 10_000 cents when config is absent" do
      Application.delete_env(:content_forge, :generation_budget)

      assert 10_000 ==
               GenerationBudget.remaining_generation_budget(Ecto.UUID.generate())
    end
  end
end
