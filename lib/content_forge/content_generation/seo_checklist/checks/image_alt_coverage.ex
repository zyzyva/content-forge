defmodule ContentForge.ContentGeneration.SeoChecklist.Checks.ImageAltCoverage do
  @moduledoc """
  Every image in the draft must have an `alt` attribute with
  non-empty text. Counts `<img>` tags and markdown `![]()` image
  syntax; fails if any image lacks an alt.
  """

  def check(%{content: content}) when is_binary(content) do
    html_images = extract_html_images(content)
    md_images = extract_markdown_images(content)
    total = length(html_images) + length(md_images)

    case total do
      0 ->
        {:not_applicable, "no images in draft"}

      _ ->
        missing_html = Enum.count(html_images, fn alt -> alt in [nil, ""] end)

        missing_md =
          Enum.count(md_images, fn alt ->
            alt == "" or is_nil(alt)
          end)

        missing = missing_html + missing_md

        if missing == 0 do
          {:pass, "#{total} images, all with alt text"}
        else
          {:fail, "#{missing}/#{total} images missing alt text"}
        end
    end
  end

  def check(_), do: {:not_applicable, "draft has no content"}

  defp extract_html_images(content) do
    Regex.scan(~r/<img\b([^>]*)>/i, content, capture: :all_but_first)
    |> Enum.map(fn [attrs] ->
      case Regex.run(~r/alt\s*=\s*["']([^"']*)["']/i, attrs) do
        [_, alt] -> alt
        _ -> nil
      end
    end)
  end

  defp extract_markdown_images(content) do
    Regex.scan(~r/!\[([^\]]*)\]\([^)]+\)/, content, capture: :all_but_first)
    |> Enum.map(fn [alt] -> alt end)
  end
end
