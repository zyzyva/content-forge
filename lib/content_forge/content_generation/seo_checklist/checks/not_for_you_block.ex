defmodule ContentForge.ContentGeneration.SeoChecklist.Checks.NotForYouBlock do
  @moduledoc """
  Per CONTENT_FORGE_SPEC Feature 10, every long-form piece
  includes an honest "Not For You" section telling the reader
  when the product is a bad fit. Detected as a heading whose
  text contains "Not For You", "Who This Is Not For", "When Not
  To", or close variants.
  """

  def check(%{content: content}) when is_binary(content) do
    if not_for_you_heading?(content) do
      {:pass, "Not-For-You section present"}
    else
      {:fail, "no Not-For-You / Who-This-Is-Not-For section"}
    end
  end

  def check(_), do: {:fail, "draft has no content"}

  defp not_for_you_heading?(content) do
    Regex.match?(
      ~r/^\s*\#{1,6}\s+.*(not\s+for\s+you|who\s+this\s+is\s+not\s+for|when\s+not\s+to|if\s+you\s+should\s+(not|skip)).*$/im,
      content
    ) or
      Regex.match?(
        ~r/<h[1-6][^>]*>\s*(not\s+for\s+you|who\s+this\s+is\s+not\s+for|when\s+not\s+to|if\s+you\s+should\s+(not|skip))[^<]*<\/h[1-6]>/i,
        content
      )
  end
end
