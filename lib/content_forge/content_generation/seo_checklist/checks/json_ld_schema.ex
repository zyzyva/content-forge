defmodule ContentForge.ContentGeneration.SeoChecklist.Checks.JsonLdSchema do
  @moduledoc """
  The draft must include at least one JSON-LD schema block
  (`<script type="application/ld+json">...</script>`). Any schema
  type counts - Article, FAQPage, HowTo, Product, etc. - because
  this is the broad "is there structured data" check; specific
  types are enforced by narrower checks.
  """

  def check(%{content: content}) when is_binary(content) do
    if Regex.match?(
         ~r/<script[^>]*type\s*=\s*["']application\/ld\+json["'][^>]*>\s*\{/i,
         content
       ) do
      {:pass, "JSON-LD schema block present"}
    else
      {:fail, "no JSON-LD schema block"}
    end
  end

  def check(_), do: {:fail, "draft has no content"}
end
