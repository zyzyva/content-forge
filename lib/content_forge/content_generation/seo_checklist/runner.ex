defmodule ContentForge.ContentGeneration.SeoChecklist.Runner do
  @moduledoc """
  Dispatches the 28-point SEO checklist against a blog draft.

  The canonical list of checks is the module attribute `@checks`
  below. Each entry is `{name_atom, module}`. Running the
  checklist calls `module.check(draft)` for each entry, collects
  the `{status, note}` results into a map keyed by the name, and
  persists a single `SeoChecklist` row per draft (unique fk).

  Re-running the checklist upserts - the `(draft_id)` unique
  index guards against duplicates.

  Phase 12.2a ships this infrastructure with 4 real checks; the
  remaining 24 are stub modules returning `:not_applicable`.
  12.2b and 12.2c fill them in.
  """

  alias ContentForge.ContentGeneration.Draft
  alias ContentForge.ContentGeneration.SeoChecklist
  alias ContentForge.ContentGeneration.SeoChecklist.Checks
  alias ContentForge.Repo

  @checks [
    {:title_length, Checks.TitleLength},
    {:meta_description_length, Checks.MetaDescriptionLength},
    {:single_h1, Checks.SingleH1},
    {:core_answer_in_first_150_words, Checks.CoreAnswerInFirst150Words},
    {:heading_hierarchy, Checks.HeadingHierarchy},
    {:fast_scan_summary_first_200, Checks.FastScanSummaryFirst200},
    {:faq_present, Checks.FaqPresent},
    {:json_ld_schema, Checks.JsonLdSchema},
    {:image_alt_coverage, Checks.ImageAltCoverage},
    {:internal_links, Checks.InternalLinks},
    {:external_link_count, Checks.ExternalLinkCount},
    {:keyword_density_title, Checks.KeywordDensityTitle},
    {:slug_length, Checks.SlugLength},
    {:toc_long_articles, Checks.TocLongArticles},
    {:reading_time_estimate, Checks.ReadingTimeEstimate},
    {:information_gain, Checks.InformationGain},
    {:entity_density, Checks.EntityDensity},
    {:paa_coverage, Checks.PaaCoverage},
    {:eeat_signals, Checks.EeatSignals},
    {:citation_presence, Checks.CitationPresence},
    {:not_for_you_block, Checks.NotForYouBlock},
    {:banned_phrases, Checks.BannedPhrases},
    {:reading_level, Checks.ReadingLevel},
    {:keyword_in_first_paragraph, Checks.KeywordInFirstParagraph},
    {:outbound_link_authority, Checks.OutboundLinkAuthority},
    {:image_count, Checks.ImageCount},
    {:minimum_word_count, Checks.MinimumWordCount},
    {:schema_article, Checks.SchemaArticle}
  ]

  @doc """
  Returns the full list of `{check_name, module}` tuples. Useful
  for tests that want to assert every check is dispatched.
  """
  def checks, do: @checks

  @doc """
  Runs every check against `draft` and persists a single
  `SeoChecklist` row per draft (upserted by `draft_id`). Also
  updates `draft.seo_score` for quick-query access.

  Returns `{:ok, %SeoChecklist{}}` or `{:error, changeset}`.
  """
  def run(%Draft{id: draft_id} = draft) do
    results =
      @checks
      |> Enum.map(fn {name, mod} -> {name, run_one(mod, draft)} end)
      |> Map.new(fn {name, {status, note}} ->
        {Atom.to_string(name), %{"status" => Atom.to_string(status), "note" => note}}
      end)

    score = score_from_results(results)
    now = DateTime.utc_now()

    with {:ok, checklist} <- upsert(draft_id, results, score, now),
         {:ok, _} <- update_draft_score(draft, score) do
      {:ok, checklist}
    end
  end

  @doc """
  Looks up the stored checklist for a draft. Returns `nil` if
  none has run yet.
  """
  def get_for_draft(draft_id) do
    Repo.get_by(SeoChecklist, draft_id: draft_id)
  end

  defp run_one(mod, draft) do
    mod.check(draft)
  rescue
    error ->
      {:fail, "check raised: #{inspect(error)}"}
  end

  defp score_from_results(results) do
    Enum.count(results, fn {_name, %{"status" => status}} -> status == "pass" end)
  end

  defp upsert(draft_id, results, score, run_at) do
    attrs = %{
      draft_id: draft_id,
      results: results,
      score: score,
      run_at: run_at
    }

    case Repo.get_by(SeoChecklist, draft_id: draft_id) do
      nil ->
        %SeoChecklist{}
        |> SeoChecklist.changeset(attrs)
        |> Repo.insert()

      existing ->
        existing
        |> SeoChecklist.changeset(attrs)
        |> Repo.update()
    end
  end

  defp update_draft_score(%Draft{} = draft, score) do
    draft
    |> Draft.changeset(%{seo_score: score})
    |> Repo.update()
  end
end
