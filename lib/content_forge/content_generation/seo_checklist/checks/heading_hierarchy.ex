defmodule ContentForge.ContentGeneration.SeoChecklist.Checks.HeadingHierarchy do
  @moduledoc """
  Heading hierarchy must not skip levels (e.g., `# Title` followed
  by `### Subsection` with no `##` in between). Scans markdown `#`
  lines and HTML `<h1>..<h6>` tags.
  """

  def check(%{content: content}) when is_binary(content) do
    case collect_heading_levels(content) do
      [] ->
        {:not_applicable, "no headings present"}

      levels ->
        case first_skip(levels) do
          nil -> {:pass, "#{length(levels)} headings in order"}
          {prev, next} -> {:fail, "H#{prev} followed by H#{next} skips a level"}
        end
    end
  end

  def check(_), do: {:not_applicable, "draft has no content"}

  defp collect_heading_levels(content) do
    markdown =
      Regex.scan(~r/^(\#{1,6})\s+/m, content, capture: :all_but_first)
      |> Enum.map(fn [hashes] -> String.length(hashes) end)

    html =
      Regex.scan(~r/<h([1-6])[^>]*>/i, content, capture: :all_but_first)
      |> Enum.map(fn [digit] -> String.to_integer(digit) end)

    markdown ++ html
  end

  defp first_skip([]), do: nil
  defp first_skip([_]), do: nil

  defp first_skip([prev, next | rest]) do
    if next > prev + 1 do
      {prev, next}
    else
      first_skip([next | rest])
    end
  end
end
