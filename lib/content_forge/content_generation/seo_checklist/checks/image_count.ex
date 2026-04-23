defmodule ContentForge.ContentGeneration.SeoChecklist.Checks.ImageCount do
  @moduledoc """
  A long-form blog article should include at least one image.
  Counts `<img>` tags and markdown `![...](...)` images.
  """

  @min 1

  def check(%{content: content}) when is_binary(content) do
    html = Regex.scan(~r/<img\b[^>]*>/i, content) |> length()
    md = Regex.scan(~r/!\[[^\]]*\]\([^)]+\)/, content) |> length()
    total = html + md

    if total >= @min do
      {:pass, "#{total} image(s)"}
    else
      {:fail, "#{total} images (expected >= #{@min})"}
    end
  end

  def check(_), do: {:fail, "draft has no content"}
end
