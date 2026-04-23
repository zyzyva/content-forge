defmodule ContentForge.ContentGeneration.SeoChecklist.Checks.SingleH1 do
  @moduledoc """
  The draft must contain exactly one H1. Checks both markdown
  (`# ...`) and HTML (`<h1>...</h1>`) forms and sums them.

  A missing H1 is a fail (not `:not_applicable`) because every
  blog article needs a title. Multiple H1s is also a fail - they
  confuse SERP snippet extraction.
  """

  def check(%{content: content}) when is_binary(content) do
    case count_h1s(content) do
      0 -> {:fail, "no H1 in draft"}
      1 -> {:pass, "exactly one H1"}
      n -> {:fail, "#{n} H1s in draft (expected 1)"}
    end
  end

  def check(_), do: {:fail, "draft has no content"}

  defp count_h1s(content) do
    markdown = Regex.scan(~r/^\s*#\s+.+$/m, content) |> length()
    html = Regex.scan(~r/<h1[^>]*>.+?<\/h1>/is, content) |> length()
    markdown + html
  end
end
