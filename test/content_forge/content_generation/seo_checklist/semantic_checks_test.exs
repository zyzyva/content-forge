defmodule ContentForge.ContentGeneration.SeoChecklist.SemanticChecksTest do
  @moduledoc """
  Unit coverage for the 10 semantic checks shipped in Phase
  12.2c. Covers both mechanical semantic heuristics (reading
  level, entity density, citation presence, image count,
  schema article, eeat signals, not-for-you block) and the
  LLM / SERP-dependent checks that return `:not_applicable`
  with a clear note when their upstreams are unavailable.
  """
  use ExUnit.Case, async: false

  alias ContentForge.ContentGeneration.SeoChecklist.Checks

  describe "InformationGain.check/1" do
    setup :clear_upstream_config

    test ":not_applicable when LLM is not configured" do
      assert {:not_applicable, note} = Checks.InformationGain.check(%{content: "body"})
      assert note =~ "LLM not configured"
    end

    test ":not_applicable when LLM is configured but Apify is not" do
      set_anthropic_key("sk-test")

      assert {:not_applicable, note} = Checks.InformationGain.check(%{content: "body"})
      assert note =~ "Apify"
    end

    test ":not_applicable with pipeline-deferred note when both configured" do
      set_anthropic_key("sk-test")
      set_apify_token("apify-test")

      assert {:not_applicable, note} = Checks.InformationGain.check(%{content: "body"})
      assert note =~ "deferred"
    end
  end

  describe "EntityDensity.check/1" do
    test ":pass when entity count meets 1-per-30-word floor" do
      content =
        "Stripe charges 2.9% per charge. Payouts in 3 days. San Francisco office opened January 2026 alongside the London and Tokyo hubs. Carrier Lennox brands."

      assert {:pass, _} = Checks.EntityDensity.check(%{content: content})
    end

    test ":fail when the body is generic prose with no entities" do
      content = String.duplicate("the system helps users who want easy workflows ", 10)
      assert {:fail, _} = Checks.EntityDensity.check(%{content: content})
    end

    test ":fail when body has no text" do
      assert {:fail, _} = Checks.EntityDensity.check(%{content: ""})
    end
  end

  describe "PaaCoverage.check/1" do
    setup :clear_upstream_config

    test ":not_applicable when Apify is not configured" do
      assert {:not_applicable, note} = Checks.PaaCoverage.check(%{content: "body"})
      assert note =~ "Apify"
    end

    test ":not_applicable with deferred note when Apify is configured" do
      set_apify_token("apify-test")

      assert {:not_applicable, note} = Checks.PaaCoverage.check(%{content: "body"})
      assert note =~ "deferred"
    end
  end

  describe "EeatSignals.check/1" do
    test ":pass when all three markers are present" do
      content = """
      author: Alex Hernandez
      published: Feb 2026
      Reviewed by Pat Doe, PhD with years of experience.

      Body here.
      """

      assert {:pass, _} = Checks.EeatSignals.check(%{content: content})
    end

    test ":fail when author is missing" do
      content = "Published on Feb 2026. Reviewed by editorial."
      assert {:fail, note} = Checks.EeatSignals.check(%{content: content})
      assert note =~ "author"
    end

    test ":fail when expertise marker is missing" do
      content = "by Alex Hernandez. Published on Feb 2026."
      assert {:fail, note} = Checks.EeatSignals.check(%{content: content})
      assert note =~ "expertise"
    end
  end

  describe "CitationPresence.check/1" do
    test ":pass when citations keep up with numeric claims" do
      content = """
      Stripe charges 2.9% per charge. Payouts run in 3 days as reported in 2026.
      [Source](https://stripe.com/pricing)
      """

      assert {:pass, _} = Checks.CitationPresence.check(%{content: content})
    end

    test ":fail when numeric claims exceed 3x the citation count" do
      content = """
      Rates: 1.5%, 2.9%, 3.5%, 4.1%, 5.0%, 6.2%, 7.3%, 8.4%.
      Prices start at $9.99, $19.99, $29.99, $39.99.
      Years: 2020, 2021, 2022, 2023, 2024, 2025.
      """

      assert {:fail, _} = Checks.CitationPresence.check(%{content: content})
    end

    test ":not_applicable when no numeric claims are present" do
      assert {:not_applicable, _} =
               Checks.CitationPresence.check(%{
                 content: "Purely qualitative reflection on workflow ergonomics."
               })
    end
  end

  describe "NotForYouBlock.check/1" do
    test ":pass when a 'Not For You' heading is present" do
      content = "## Not For You\n\nThis product is a poor fit for teams under 5 users."
      assert {:pass, _} = Checks.NotForYouBlock.check(%{content: content})
    end

    test ":pass for 'Who This Is Not For'" do
      content = "### Who This Is Not For\n\nSolo hobbyists."
      assert {:pass, _} = Checks.NotForYouBlock.check(%{content: content})
    end

    test ":fail when no such section is present" do
      assert {:fail, _} = Checks.NotForYouBlock.check(%{content: "# Article\n\nBody."})
    end
  end

  describe "ReadingLevel.check/1" do
    test ":pass for moderately complex prose" do
      # Accessible narrative with everyday words; lands inside
      # the 50..80 Flesch target band.
      content =
        "Local bakeries across the neighborhood serve fresh bread every morning. Residents line up early to pick up their orders. Some customers prefer sourdough while others ask for whole wheat. The owners greet everyone by name. Weekend hours extend until evening."

      assert {:pass, _} = Checks.ReadingLevel.check(%{content: content})
    end

    test ":fail for extremely dense academic prose" do
      content =
        "Algorithmic interoperability presupposes epistemological compatibility between heterogeneous distributed architectures. Ontological reconciliation requires schema-level isomorphism among multidimensional representational frameworks. Incompatibility manifests pathologically across hierarchical taxonomies of inference encompassing symbolic and subsymbolic paradigms, necessitating reconstruction across multiple epistemological substrates simultaneously."

      assert {:fail, _} = Checks.ReadingLevel.check(%{content: content})
    end

    test ":not_applicable for content under the min word threshold" do
      assert {:not_applicable, _} = Checks.ReadingLevel.check(%{content: "short draft"})
    end
  end

  describe "OutboundLinkAuthority.check/1" do
    setup :clear_upstream_config

    test ":not_applicable when there are no external links" do
      content = "Pure internal: [home](/)"
      assert {:not_applicable, _} = Checks.OutboundLinkAuthority.check(%{content: content})
    end

    test ":pass via HTTPS-only fallback when Apify is not configured" do
      content = ~s(<a href="https://example.com">ex</a>)
      assert {:pass, note} = Checks.OutboundLinkAuthority.check(%{content: content})
      assert note =~ "fallback"
    end

    test ":fail via fallback when a non-HTTPS external link is present" do
      content = ~s(<a href="http://example.com">ex</a>)
      assert {:fail, _} = Checks.OutboundLinkAuthority.check(%{content: content})
    end

    test ":not_applicable with deferred note when Apify is configured" do
      set_apify_token("apify-test")

      content = ~s(<a href="https://example.com">ex</a>)
      assert {:not_applicable, note} = Checks.OutboundLinkAuthority.check(%{content: content})
      assert note =~ "deferred"
    end
  end

  describe "ImageCount.check/1" do
    test ":pass when at least one image is present" do
      assert {:pass, _} =
               Checks.ImageCount.check(%{content: ~s(<img src="a.jpg" alt="a">)})
    end

    test ":pass via markdown image" do
      assert {:pass, _} = Checks.ImageCount.check(%{content: "![alt](img.png)"})
    end

    test ":fail when no images are present" do
      assert {:fail, _} = Checks.ImageCount.check(%{content: "text only"})
    end
  end

  describe "SchemaArticle.check/1" do
    test ":pass for an Article JSON-LD block" do
      content = ~s|<script type="application/ld+json">{"@type":"Article"}</script>|
      assert {:pass, _} = Checks.SchemaArticle.check(%{content: content})
    end

    test ":pass for a BlogPosting subtype" do
      content = ~s|{"@type":"BlogPosting"}|
      assert {:pass, _} = Checks.SchemaArticle.check(%{content: content})
    end

    test ":fail for a FAQPage-only schema (different type)" do
      content = ~s|{"@type":"FAQPage"}|
      assert {:fail, _} = Checks.SchemaArticle.check(%{content: content})
    end
  end

  # Stubs the Application config the Anthropic and Apify clients
  # read via `Application.get_env`. Clearing the tokens makes
  # `.status()` return `:not_configured`; the helpers below put
  # them back when a test needs the configured branch.
  defp clear_upstream_config(_ctx) do
    llm_before = Application.get_env(:content_forge, :llm, [])
    apify_before = Application.get_env(:content_forge, :apify, [])

    zero_anthropic = Keyword.put(llm_before, :anthropic, api_key: nil)
    zero_apify = Keyword.put(apify_before, :token, nil)

    Application.put_env(:content_forge, :llm, zero_anthropic)
    Application.put_env(:content_forge, :apify, zero_apify)

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:content_forge, :llm, llm_before)
      Application.put_env(:content_forge, :apify, apify_before)
    end)

    :ok
  end

  defp set_anthropic_key(key) do
    llm = Application.get_env(:content_forge, :llm, [])

    updated =
      Keyword.update(llm, :anthropic, [api_key: key], fn inner ->
        Keyword.put(inner, :api_key, key)
      end)

    Application.put_env(:content_forge, :llm, updated)
  end

  defp set_apify_token(token) do
    apify = Application.get_env(:content_forge, :apify, [])
    Application.put_env(:content_forge, :apify, Keyword.put(apify, :token, token))
  end
end
