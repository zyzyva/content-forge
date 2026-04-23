defmodule ContentForge.ContentGeneration.SeoChecklist.ChecksTest do
  @moduledoc """
  Unit tests for the 4 implemented SEO checks in Phase 12.2a.
  """
  use ExUnit.Case, async: true

  alias ContentForge.ContentGeneration.SeoChecklist.Checks

  describe "TitleLength.check/1" do
    test ":pass for titles at or below 60 chars" do
      draft = %{content: "# A Short Title Well Under Sixty Chars"}
      assert {:pass, _} = Checks.TitleLength.check(draft)
    end

    test ":fail for titles over 60 chars" do
      title =
        "# This is a deliberately long SEO title that definitely exceeds the sixty character budget for SERP snippets"

      assert {:fail, note} = Checks.TitleLength.check(%{content: title})
      assert note =~ "> 60"
    end

    test ":not_applicable when no H1 is present" do
      assert {:not_applicable, _} = Checks.TitleLength.check(%{content: "No heading here."})
    end

    test "reads HTML <h1> tags too" do
      assert {:pass, _} = Checks.TitleLength.check(%{content: "<h1>HTML H1 Title</h1>"})
    end
  end

  describe "MetaDescriptionLength.check/1" do
    test ":pass for HTML meta descriptions at or below 155 chars" do
      content =
        ~s(<meta name="description" content="Compact description under the 155 char SERP snippet budget.">)

      assert {:pass, _} = Checks.MetaDescriptionLength.check(%{content: content})
    end

    test ":fail for meta descriptions over 155 chars" do
      long =
        String.duplicate("x", 160)

      content = ~s(<meta name="description" content="#{long}">)
      assert {:fail, note} = Checks.MetaDescriptionLength.check(%{content: content})
      assert note =~ "> 155"
    end

    test ":not_applicable when no meta description is present" do
      assert {:not_applicable, _} =
               Checks.MetaDescriptionLength.check(%{content: "body only, no meta"})
    end

    test "reads frontmatter-style meta lines too" do
      content = "meta: A frontmatter style description under 155 chars."
      assert {:pass, _} = Checks.MetaDescriptionLength.check(%{content: content})
    end
  end

  describe "SingleH1.check/1" do
    test ":pass for exactly one H1" do
      assert {:pass, _} = Checks.SingleH1.check(%{content: "# One H1\n\nBody"})
    end

    test ":fail for no H1" do
      assert {:fail, note} = Checks.SingleH1.check(%{content: "Body paragraph only."})
      assert note =~ "no H1"
    end

    test ":fail for multiple H1s (markdown + HTML counted together)" do
      content = "# First H1\n\n<h1>Second H1</h1>\n\nBody"
      assert {:fail, note} = Checks.SingleH1.check(%{content: content})
      assert note =~ "2 H1s"
    end
  end

  describe "CoreAnswerInFirst150Words.check/1" do
    test ":pass when a declarative sentence appears in the first 150 words" do
      content =
        "Stripe charges 2.9% plus $0.30 per successful card transaction for US merchants. Payouts run on a 3 to 5 business day rolling schedule."

      assert {:pass, _} = Checks.CoreAnswerInFirst150Words.check(%{content: content})
    end

    test ":fail when the opening is only questions" do
      content =
        "Are you wondering how this works? Have you tried it before? What if it could change?"

      assert {:fail, note} = Checks.CoreAnswerInFirst150Words.check(%{content: content})
      assert note =~ "question"
    end

    test ":fail when no declarative sentence is long enough" do
      content =
        "Short. Bits. Only. Here. Nothing. Full. Claims."

      assert {:fail, _} = Checks.CoreAnswerInFirst150Words.check(%{content: content})
    end

    test ":fail for empty content" do
      assert {:fail, _} = Checks.CoreAnswerInFirst150Words.check(%{content: ""})
    end
  end
end
