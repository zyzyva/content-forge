defmodule ContentForge.ContentGeneration.SeoChecklist.Checks.FaqPresent do
  @moduledoc """
  The draft must include an FAQ section, detected either as a
  heading whose text contains "FAQ" / "Frequently Asked
  Questions" (markdown or HTML), or as a JSON-LD `FAQPage`
  schema block.
  """

  def check(%{content: content}) when is_binary(content) do
    cond do
      faq_heading?(content) -> {:pass, "FAQ heading present"}
      faq_page_schema?(content) -> {:pass, "FAQPage JSON-LD present"}
      true -> {:fail, "no FAQ section or FAQPage schema"}
    end
  end

  def check(_), do: {:fail, "draft has no content"}

  defp faq_heading?(content) do
    Regex.match?(
      ~r/^\s*\#{1,6}\s+.*(faq|frequently\s+asked\s+questions).*$/im,
      content
    ) or
      Regex.match?(
        ~r/<h[1-6][^>]*>\s*(faq|frequently\s+asked\s+questions)[^<]*<\/h[1-6]>/i,
        content
      )
  end

  defp faq_page_schema?(content) do
    Regex.match?(~r/"@type"\s*:\s*"FAQPage"/i, content)
  end
end
