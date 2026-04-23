defmodule ContentForge.ContentGeneration.SeoChecklist.Checks.SchemaArticle do
  @moduledoc """
  The draft should include a JSON-LD `Article` schema block (or
  a narrower `BlogPosting` / `NewsArticle` subtype). This is the
  narrow-type counterpart to `JsonLdSchema` which accepts any
  structured-data block.
  """

  @article_types ~w(Article BlogPosting NewsArticle)

  def check(%{content: content}) when is_binary(content) do
    if article_schema?(content) do
      {:pass, "Article JSON-LD schema present"}
    else
      {:fail, "no Article/BlogPosting/NewsArticle JSON-LD schema"}
    end
  end

  def check(_), do: {:fail, "draft has no content"}

  defp article_schema?(content) do
    Enum.any?(@article_types, fn type ->
      Regex.match?(~r/"@type"\s*:\s*"#{type}"/i, content)
    end)
  end
end
