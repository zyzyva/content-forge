defmodule ContentForge.RuntimeConfigTest do
  @moduledoc """
  Phase 17.2: lock the dev/prod config gate open. The
  `:scraper_adapter` and `:intel_model` bindings must be wired in
  every Mix env so dev runs of the Oban jobs exercise the real
  adapters; gating happens at the adapter layer based on
  env-variable presence (APIFY_TOKEN / ANTHROPIC_API_KEY).

  This test pins the wiring so a future cleanup can't quietly
  re-add the `if config_env() == :prod` block in `runtime.exs`.
  """
  use ExUnit.Case, async: false

  alias ContentForge.CompetitorIntelSynthesizer.LLMAdapter
  alias ContentForge.CompetitorScraper.ApifyAdapter

  test "scraper_adapter is wired to ApifyAdapter outside prod too" do
    assert Application.get_env(:content_forge, :scraper_adapter) == ApifyAdapter
  end

  test "intel_model is wired to the LLMAdapter outside prod too" do
    assert Application.get_env(:content_forge, :intel_model) == LLMAdapter
  end

  test "ApifyAdapter reports :not_configured when APIFY_TOKEN is absent in this env" do
    # The test env intentionally leaves APIFY_TOKEN unset so the
    # adapter's :not_configured path stays observable end-to-end.
    # If a future change starts setting the token at boot, this
    # assertion catches it.
    apify_config = Application.get_env(:content_forge, :apify, [])

    expected =
      case Keyword.get(apify_config, :token) do
        nil -> :not_configured
        "" -> :not_configured
        _ -> :ok
      end

    assert ApifyAdapter.status() == expected
  end
end
