defmodule ContentForge.ContentGeneration.SeoChecklist.Checks.BannedPhrases do
  @moduledoc """
  The draft must not contain any of the banned marketing phrases
  enumerated in the blog-generation prompt. Catching these post-
  generation keeps the gate independent of prompt drift.
  """

  @banned [
    "delve",
    "comprehensive guide",
    "in today's digital landscape",
    "it's worth noting",
    "as an AI",
    "in conclusion it's clear",
    "at the end of the day",
    "in the ever-evolving",
    "navigate the complexities"
  ]

  def check(%{content: content}) when is_binary(content) do
    lowered = String.downcase(content)
    hits = Enum.filter(@banned, &String.contains?(lowered, &1))

    case hits do
      [] -> {:pass, "no banned phrases"}
      [single] -> {:fail, "banned phrase: \"#{single}\""}
      many -> {:fail, "#{length(many)} banned phrases: #{Enum.join(many, ", ")}"}
    end
  end

  def check(_), do: {:pass, "empty content: no banned phrases to find"}
end
