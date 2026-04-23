defmodule ContentForge.ContentGeneration.SeoChecklist.MechanicalChecksTest do
  @moduledoc """
  Unit coverage for the 14 mechanical checks shipped in Phase
  12.2b. Semantic checks (12.2c territory) stay as stubs and are
  not exercised here.
  """
  use ExUnit.Case, async: true

  alias ContentForge.ContentGeneration.SeoChecklist.Checks

  describe "HeadingHierarchy.check/1" do
    test ":pass for sequential markdown headings" do
      content = "# H1\n\n## H2\n\n### H3"
      assert {:pass, _} = Checks.HeadingHierarchy.check(%{content: content})
    end

    test ":fail when a level is skipped" do
      content = "# H1\n\n### Skipped to H3"
      assert {:fail, note} = Checks.HeadingHierarchy.check(%{content: content})
      assert note =~ "H1 followed by H3"
    end

    test ":not_applicable for drafts with no headings" do
      assert {:not_applicable, _} =
               Checks.HeadingHierarchy.check(%{content: "body text with no headings"})
    end
  end

  describe "FaqPresent.check/1" do
    test ":pass for markdown FAQ heading" do
      content = "## FAQ\n\nQ1\n\nA1"
      assert {:pass, _} = Checks.FaqPresent.check(%{content: content})
    end

    test ":pass for FAQPage JSON-LD block" do
      content = ~s|<script type="application/ld+json">{"@type":"FAQPage"}</script>|
      assert {:pass, _} = Checks.FaqPresent.check(%{content: content})
    end

    test ":fail when no FAQ is present" do
      assert {:fail, _} = Checks.FaqPresent.check(%{content: "body"})
    end
  end

  describe "JsonLdSchema.check/1" do
    test ":pass for a JSON-LD script block" do
      content = ~s|<script type="application/ld+json">{"@type":"Article"}</script>|
      assert {:pass, _} = Checks.JsonLdSchema.check(%{content: content})
    end

    test ":fail when no JSON-LD block is present" do
      assert {:fail, _} = Checks.JsonLdSchema.check(%{content: "body only"})
    end
  end

  describe "ImageAltCoverage.check/1" do
    test ":pass when all images have alt text" do
      content = ~s|<img src="a.jpg" alt="picture"> ![hero](hero.jpg)|
      assert {:pass, _} = Checks.ImageAltCoverage.check(%{content: content})
    end

    test ":fail when any image lacks alt text" do
      content = ~s|<img src="a.jpg"> ![](hero.jpg)|
      assert {:fail, note} = Checks.ImageAltCoverage.check(%{content: content})
      assert note =~ "missing alt"
    end

    test ":not_applicable when no images are present" do
      assert {:not_applicable, _} = Checks.ImageAltCoverage.check(%{content: "just text"})
    end
  end

  describe "InternalLinks.check/1" do
    test ":pass for a relative href" do
      content = ~s|<a href="/pricing">pricing</a>|
      assert {:pass, _} = Checks.InternalLinks.check(%{content: content})
    end

    test ":pass for a markdown relative link" do
      assert {:pass, _} =
               Checks.InternalLinks.check(%{content: "See [pricing](/pricing) for details."})
    end

    test ":fail when only external links are present" do
      content = ~s|<a href="https://example.com">ex</a>|
      assert {:fail, _} = Checks.InternalLinks.check(%{content: content})
    end

    test ":fail when only anchor fragments are present" do
      content = "[Go to top](#top)"
      assert {:fail, _} = Checks.InternalLinks.check(%{content: content})
    end
  end

  describe "ExternalLinkCount.check/1" do
    test ":pass for a small number of external links" do
      content = ~s|<a href="https://example.com">ex</a>|
      assert {:pass, _} = Checks.ExternalLinkCount.check(%{content: content})
    end

    test ":fail when no external links are present" do
      content = ~s|<a href="/internal">internal</a>|
      assert {:fail, _} = Checks.ExternalLinkCount.check(%{content: content})
    end

    test ":fail when more than 20 external links appear" do
      urls =
        Enum.map_join(1..25, " ", fn i ->
          ~s|<a href="https://example.com/#{i}">x</a>|
        end)

      assert {:fail, note} = Checks.ExternalLinkCount.check(%{content: urls})
      assert note =~ "<= 20"
    end
  end

  describe "KeywordDensityTitle.check/1" do
    test ":pass when the title keyword appears in the first body window" do
      content = "# Stripe Checkout Fees Explained\n\nStripe charges merchants."
      assert {:pass, _} = Checks.KeywordDensityTitle.check(%{content: content})
    end

    test ":fail when the title keyword never appears in the body" do
      content = "# Stripe Checkout Fees Explained\n\nA different topic entirely."
      assert {:fail, _} = Checks.KeywordDensityTitle.check(%{content: content})
    end

    test ":not_applicable when no H1 exists" do
      assert {:not_applicable, _} = Checks.KeywordDensityTitle.check(%{content: "body"})
    end
  end

  describe "SlugLength.check/1" do
    test ":pass for a short slug" do
      assert {:pass, _} = Checks.SlugLength.check(%{content: "slug: stripe-checkout-fees"})
    end

    test ":fail for a slug over 75 chars" do
      long = String.duplicate("x", 80)
      assert {:fail, _} = Checks.SlugLength.check(%{content: "slug: #{long}"})
    end

    test ":not_applicable when no slug is set" do
      assert {:not_applicable, _} = Checks.SlugLength.check(%{content: "body"})
    end
  end

  describe "TocLongArticles.check/1" do
    test ":not_applicable for articles under 1500 words" do
      assert {:not_applicable, _} = Checks.TocLongArticles.check(%{content: "short body"})
    end

    test ":pass for long articles with a TOC heading" do
      body = String.duplicate("word ", 1600)
      content = "# Long Post\n\n## Table of Contents\n\n" <> body
      assert {:pass, _} = Checks.TocLongArticles.check(%{content: content})
    end

    test ":fail for long articles without a TOC" do
      body = String.duplicate("word ", 1600)
      content = "# Long Post\n\n" <> body
      assert {:fail, _} = Checks.TocLongArticles.check(%{content: content})
    end
  end

  describe "ReadingTimeEstimate.check/1" do
    test ":pass when a reading-time phrase is present" do
      assert {:pass, _} = Checks.ReadingTimeEstimate.check(%{content: "5 minute read"})
    end

    test ":pass for the colon-form phrase" do
      assert {:pass, _} = Checks.ReadingTimeEstimate.check(%{content: "Reading time: 7 min"})
    end

    test ":fail when no reading-time phrase is present" do
      assert {:fail, _} = Checks.ReadingTimeEstimate.check(%{content: "body only"})
    end
  end

  describe "FastScanSummaryFirst200.check/1" do
    test ":pass when ai_summary_nugget is populated" do
      draft = %{content: "body", ai_summary_nugget: "Stripe: 2.9% per charge. Payouts in 3 days."}
      assert {:pass, note} = Checks.FastScanSummaryFirst200.check(draft)
      assert note =~ "AI Summary Nugget"
    end

    test ":pass via fallback when body opens with multiple complete sentences" do
      content =
        "Stripe charges 2.9% + $0.30 per card transaction for US merchants. Payouts land in 3 business days. More detail follows."

      assert {:pass, _} = Checks.FastScanSummaryFirst200.check(%{content: content})
    end

    test ":fail when the first 200 words contain no complete sentence" do
      assert {:fail, _} = Checks.FastScanSummaryFirst200.check(%{content: "short fragment"})
    end
  end

  describe "BannedPhrases.check/1" do
    test ":pass when no banned phrase appears" do
      assert {:pass, _} = Checks.BannedPhrases.check(%{content: "clean body."})
    end

    test ":fail when a banned phrase appears" do
      assert {:fail, note} =
               Checks.BannedPhrases.check(%{content: "Let's delve into the details."})

      assert note =~ "delve"
    end
  end

  describe "MinimumWordCount.check/1" do
    test ":pass for content >= 800 words" do
      body = String.duplicate("word ", 900)
      assert {:pass, _} = Checks.MinimumWordCount.check(%{content: body})
    end

    test ":fail for short content" do
      assert {:fail, _} = Checks.MinimumWordCount.check(%{content: "short draft"})
    end
  end

  describe "KeywordInFirstParagraph.check/1" do
    test ":pass when the title keyword appears in the first paragraph" do
      content = "# Stripe Payouts Guide\n\nStripe payouts settle in 3 business days."
      assert {:pass, _} = Checks.KeywordInFirstParagraph.check(%{content: content})
    end

    test ":fail when the first paragraph does not mention the title keyword" do
      content = "# Stripe Payouts Guide\n\nWe discuss unrelated taxonomy here."
      assert {:fail, _} = Checks.KeywordInFirstParagraph.check(%{content: content})
    end

    test ":not_applicable when no H1 exists" do
      assert {:not_applicable, _} = Checks.KeywordInFirstParagraph.check(%{content: "body"})
    end
  end
end
