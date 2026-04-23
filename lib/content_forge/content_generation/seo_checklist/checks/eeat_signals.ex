defmodule ContentForge.ContentGeneration.SeoChecklist.Checks.EeatSignals do
  @moduledoc """
  E-E-A-T (Experience, Expertise, Authoritativeness, Trust)
  surface signals. Looks for three mechanical markers that must
  all be present for a pass:

    * an author byline (`by <name>`, `author:` frontmatter, or
      `<span class="author">` / `rel="author"` markup)
    * a publish date (`published:` frontmatter, `<time datetime>`,
      or `Published <date>` prose)
    * an expertise marker (credentials / years-experience /
      "reviewed by" / "medically reviewed" / "verified by")

  Partial coverage is a fail with the missing markers listed.
  """

  def check(%{content: content}) when is_binary(content) do
    lowered = String.downcase(content)

    signals = %{
      author: author_present?(content, lowered),
      date: date_present?(content, lowered),
      expertise: expertise_present?(lowered)
    }

    missing =
      signals
      |> Enum.filter(fn {_, present?} -> not present? end)
      |> Enum.map(fn {key, _} -> Atom.to_string(key) end)

    case missing do
      [] -> {:pass, "author + date + expertise markers present"}
      _ -> {:fail, "missing E-E-A-T markers: #{Enum.join(missing, ", ")}"}
    end
  end

  def check(_), do: {:fail, "draft has no content"}

  defp author_present?(content, lowered) do
    String.contains?(lowered, "author:") or
      Regex.match?(~r/\bby\s+[A-Z][a-z]+\s+[A-Z][a-z]+/, content) or
      Regex.match?(~r/rel\s*=\s*["']author["']/i, content) or
      Regex.match?(~r/class\s*=\s*["']author["']/i, content)
  end

  defp date_present?(content, lowered) do
    String.contains?(lowered, "published:") or
      String.contains?(lowered, "updated:") or
      Regex.match?(~r/<time[^>]*datetime\s*=/i, content) or
      Regex.match?(~r/\b(published|updated)\s+(on\s+)?(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)/i, content)
  end

  defp expertise_present?(lowered) do
    String.contains?(lowered, "reviewed by") or
      String.contains?(lowered, "medically reviewed") or
      String.contains?(lowered, "verified by") or
      String.contains?(lowered, "years of experience") or
      Regex.match?(~r/\b(phd|md|cpa|cfa|pmp|mba)\b/i, lowered)
  end
end
