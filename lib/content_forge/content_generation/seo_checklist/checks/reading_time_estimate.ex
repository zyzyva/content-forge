defmodule ContentForge.ContentGeneration.SeoChecklist.Checks.ReadingTimeEstimate do
  @moduledoc """
  The draft should include a reading-time estimate. Detected as
  any "X minute read", "X-minute read", or "Reading time: X min"
  phrase in the body.
  """

  def check(%{content: content}) when is_binary(content) do
    if reading_time_phrase?(content) do
      {:pass, "reading-time estimate present"}
    else
      {:fail, "no reading-time estimate"}
    end
  end

  def check(_), do: {:fail, "draft has no content"}

  defp reading_time_phrase?(content) do
    Regex.match?(
      ~r/(\d+\s*-?\s*(min|minute)s?\s+read|reading\s+time\s*[:\-]\s*\d+\s*(min|minute)s?)/i,
      content
    )
  end
end
