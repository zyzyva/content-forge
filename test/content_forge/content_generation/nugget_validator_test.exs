defmodule ContentForge.ContentGeneration.NuggetValidatorTest do
  @moduledoc """
  Unit tests for the Phase 12.1 AI Summary Nugget validator.

  Criteria under test (from BUILDPLAN 12.1):

    * length 100..250 chars after stripping
    * at least two entity-style tokens (proper nouns or numbers)
    * no disallowed hedging phrases
    * no pronouns referring to outside context (detected via
      leading-pronoun heuristic)
  """
  use ExUnit.Case, async: true

  alias ContentForge.ContentGeneration.NuggetValidator

  @valid_nugget "Stripe: 2.9% + $0.30 per charge, 3-5 day payout, USD and EUR supported. Published Feb 2026 after the Checkout API rewrite that shipped January 15."

  describe "validate/1 happy path" do
    test "returns {:ok, nugget} for a well-formed first paragraph" do
      assert {:ok, trimmed} = NuggetValidator.validate(@valid_nugget)
      assert String.length(trimmed) >= 100
      assert String.length(trimmed) <= 250
    end

    test "extracts the first paragraph when the draft has multiple paragraphs" do
      body = @valid_nugget <> "\n\nThe rest of the article talks about other things."
      assert {:ok, trimmed} = NuggetValidator.validate(body)
      assert trimmed == @valid_nugget
    end
  end

  describe "validate/1 length guard" do
    test "returns :too_short for nuggets under 100 chars" do
      assert {:error, reasons} = NuggetValidator.validate("Stripe charges 2.9%.")
      assert :too_short in reasons
    end

    test "returns :too_long for nuggets over 250 chars" do
      long =
        "Stripe: " <>
          String.duplicate(
            "2.9% + $0.30 per charge, 3-5 day payout, USD and EUR supported. ",
            10
          )

      assert {:error, reasons} = NuggetValidator.validate(long)
      assert :too_long in reasons
    end
  end

  describe "validate/1 entity token guard" do
    test "returns :insufficient_entity_tokens when fewer than 2 entities appear" do
      soft =
        "the system offers fast turnaround and reliable service to all clients across the market which is nice for everyone involved in planning."

      assert {:error, reasons} = NuggetValidator.validate(soft)
      assert :insufficient_entity_tokens in reasons
    end

    test "accepts numbers and proper nouns as entity tokens" do
      assert {:ok, _} =
               NuggetValidator.validate(
                 "Stripe: 2.9% per charge, 3 business-day payouts, 135 currencies supported. Shipped January 15 in the San Francisco office."
               )
    end
  end

  describe "validate/1 hedging guard" do
    test "returns :contains_hedging when a hedging phrase is present" do
      hedgy =
        "Stripe might possibly offer 2.9% per charge, sort of 3 day payouts, and perhaps 135 currencies supported. Shipped January 2026."

      assert {:error, reasons} = NuggetValidator.validate(hedgy)
      assert :contains_hedging in reasons
    end
  end

  describe "validate/1 pronoun guard" do
    test "returns :outside_pronoun_reference when the nugget opens with a dangling pronoun" do
      opener =
        "This is why Stripe charges 2.9% per transaction, delivers payouts in 3 business days, and supports 135 currencies across San Francisco, London, and Tokyo."

      assert {:error, reasons} = NuggetValidator.validate(opener)
      assert :outside_pronoun_reference in reasons
    end

    test "accepts openings that lead with a proper noun" do
      assert {:ok, _} = NuggetValidator.validate(@valid_nugget)
    end
  end
end
