defmodule ContentForge.ContentGeneration.SeoChecklist.Checks.MinimumWordCount do
  @moduledoc """
  Blog articles must hit a minimum word count for SEO ranking.
  Default floor is 800 words. Content below the floor fails with
  the actual count in the note so operators know how far short.
  """

  @min 800

  def check(%{content: content}) when is_binary(content) do
    count = count_words(content)

    if count >= @min do
      {:pass, "#{count} words"}
    else
      {:fail, "#{count} words < #{@min}"}
    end
  end

  def check(_), do: {:fail, "draft has no content"}

  defp count_words(content) do
    content
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end
end
