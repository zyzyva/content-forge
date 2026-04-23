defmodule ContentForge.ContentGeneration.NuggetValidator do
  @moduledoc """
  Validates the AI Summary Nugget (Phase 12.1) at the top of a
  blog draft. The nugget is the first paragraph and must be a
  self-contained factual summary so AI assistants citing the
  article get a correct answer from that paragraph alone.

  Criteria (all must pass):

    * length 100..250 characters after stripping leading /
      trailing whitespace
    * at least two entity-style tokens (proper nouns or numeric
      runs)
    * no disallowed hedging phrases (see `@hedging_phrases`)
    * does not open with a pronoun that would be a dangling
      reference to outside context

  Returns:

    * `{:ok, trimmed_nugget}` when every criterion passes
    * `{:error, [atom]}` listing each failed criterion. The
      caller uses this list to populate a human-readable error
      on the draft.
  """

  @min_length 100
  @max_length 250
  @min_entity_tokens 2

  @hedging_phrases [
    "sort of",
    "kind of",
    "might possibly",
    "perhaps",
    "seems to",
    "could be",
    "maybe",
    "probably",
    "arguably",
    "somewhat",
    "fairly",
    "rather"
  ]

  @leading_pronouns ~w(this that these those it they them he she who which there here)

  @doc """
  Validates a blob of text (the draft body). Returns `{:ok,
  nugget}` if the first paragraph meets every criterion,
  otherwise `{:error, reasons}`.
  """
  def validate(text) when is_binary(text) do
    nugget =
      text
      |> first_paragraph()
      |> String.trim()

    reasons =
      []
      |> maybe_add(length_reason(nugget))
      |> maybe_add(entity_reason(nugget))
      |> maybe_add(hedging_reason(nugget))
      |> maybe_add(pronoun_reason(nugget))
      |> Enum.reverse()

    case reasons do
      [] -> {:ok, nugget}
      list -> {:error, list}
    end
  end

  def validate(_), do: {:error, [:not_a_string]}

  @doc """
  Renders a reasons list into a compact human-readable string for
  `Draft.error`.
  """
  def format_reasons(reasons) when is_list(reasons) do
    "nugget validation failed: " <> Enum.map_join(reasons, ", ", &Atom.to_string/1)
  end

  defp first_paragraph(text) do
    text
    |> String.split(~r/\n\s*\n/, parts: 2)
    |> List.first()
    |> Kernel.||("")
  end

  defp maybe_add(reasons, nil), do: reasons
  defp maybe_add(reasons, reason), do: [reason | reasons]

  defp length_reason(text) do
    len = String.length(text)

    cond do
      len < @min_length -> :too_short
      len > @max_length -> :too_long
      true -> nil
    end
  end

  defp entity_reason(text) do
    if count_entity_tokens(text) >= @min_entity_tokens do
      nil
    else
      :insufficient_entity_tokens
    end
  end

  defp count_entity_tokens(text) do
    text
    |> String.split(~r/[\s,.;:!?()\[\]]+/, trim: true)
    |> Enum.count(&entity_token?/1)
  end

  defp entity_token?(token) do
    numeric_token?(token) or proper_noun_token?(token)
  end

  defp numeric_token?(token), do: Regex.match?(~r/\d/, token)

  defp proper_noun_token?(token) do
    # Starts with an uppercase letter and is not a leading-of-
    # sentence common word (the first word of any sentence is
    # capitalized, which would inflate the count with non-
    # entity words like "This" or "The"). We approximate by
    # requiring the token to contain at least one additional
    # uppercase letter OR to be mixed-case beyond the first
    # character OR to contain a digit.
    case token do
      <<first::utf8, _rest::binary>> when first in ?A..?Z ->
        multi_cap?(token) or hyphenated_proper?(token) or not common_lowercase_cousin?(token)

      _ ->
        false
    end
  end

  defp multi_cap?(token) do
    String.graphemes(token)
    |> Enum.count(fn g -> g == String.upcase(g) and g =~ ~r/[A-Z]/ end)
    |> Kernel.>=(2)
  end

  defp hyphenated_proper?(token), do: String.contains?(token, "-")

  @common_words ~w(This That These Those The A An It They We You I And But Or If Then When Where Why How What Who)
  defp common_lowercase_cousin?(token), do: token in @common_words

  defp hedging_reason(text) do
    lowered = String.downcase(text)

    if Enum.any?(@hedging_phrases, &String.contains?(lowered, &1)) do
      :contains_hedging
    end
  end

  defp pronoun_reason(text) do
    case leading_word(text) do
      nil -> nil
      word -> if word in @leading_pronouns, do: :outside_pronoun_reference
    end
  end

  defp leading_word(text) do
    text
    |> String.trim_leading()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> case do
      nil -> nil
      "" -> nil
      word -> word |> String.replace(~r/[^\w]/, "") |> String.downcase()
    end
  end
end
