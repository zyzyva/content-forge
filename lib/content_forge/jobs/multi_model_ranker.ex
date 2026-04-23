defmodule ContentForge.Jobs.MultiModelRanker do
  @moduledoc """
  Oban job that scores drafts using real LLM providers (Claude + Gemini).

  Each provider scores on: accuracy (0-10), SEO relevance (0-10), and
  entertainment/education value (0-10). The scoring prompt carries the
  draft, the brief, and the calibration + scoreboard context; the
  provider is asked to return a structured JSON object with the three
  dimensions and a short critique.

  Results are stored per (draft, model) pair. Top N per content type by
  composite score are promoted to `ranked`; the remainder stay `draft`.

  Downgrade rules:

    * `{:error, :not_configured}` from a provider is a per-model skip
      (no score row, no fabricated value). The draft still ranks on the
      remaining provider when one is configured.
    * If neither provider is configured, the job runs to completion but
      does not promote anything - better to pause promotion than to
      promote drafts ranked on synthetic signal.
    * A malformed JSON reply from a provider is treated as a permanent
      skip for that (draft, model) pair: no row is written and the
      critique never lands as placeholder text.
    * Transient HTTP errors (5xx, 429, timeout, network) propagate as
      `{:error, _}` so Oban retries the whole job. Retries are safe
      because scores are upserted per (draft, model).
    * Permanent HTTP errors (4xx, unexpected_status) are logged and
      skipped per (draft, model) to avoid blocking the whole batch.

  This slice does not score with xAI; there is no xAI client yet. The
  model list is `["claude", "gemini"]`; the `DraftScore` schema still
  allows `"xai"` for when a future slice adds a third provider.
  """
  use Oban.Worker, queue: :content_generation, max_attempts: 3
  require Logger

  alias ContentForge.ContentGeneration
  alias ContentForge.ContentGeneration.DraftScore
  alias ContentForge.LLM.Anthropic
  alias ContentForge.LLM.Gemini

  @models ["claude", "gemini"]
  @default_top_n 3

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"product_id" => product_id, "content_type" => content_type, "top_n" => top_n}
      }) do
    rank_drafts(product_id, content_type, top_n || @default_top_n)
  end

  def perform(%Oban.Job{args: %{"product_id" => product_id, "content_type" => content_type}}) do
    rank_drafts(product_id, content_type, @default_top_n)
  end

  def perform(%Oban.Job{args: %{"product_id" => product_id}}) do
    rank_drafts(product_id, nil, @default_top_n)
  end

  defp rank_drafts(product_id, content_type, top_n) do
    types_to_rank =
      if content_type, do: [content_type], else: ["post", "blog", "video_script"]

    Logger.info(
      "Starting multi-model ranking for product #{product_id}, types: #{inspect(types_to_rank)}"
    )

    scoreboard_context = build_scoreboard_context(product_id)

    case rank_each(types_to_rank, product_id, top_n, scoreboard_context) do
      :ok ->
        Logger.info("Multi-model ranking complete for product #{product_id}")
        {:ok, %{ranked: true}}

      {:error, reason} ->
        Logger.warning(
          "Multi-model ranking for product #{product_id} hit a transient error: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp rank_each([], _product_id, _top_n, _ctx), do: :ok

  defp rank_each([type | rest], product_id, top_n, ctx) do
    case rank_drafts_by_type(product_id, type, top_n, ctx) do
      :ok -> rank_each(rest, product_id, top_n, ctx)
      {:error, _} = err -> err
    end
  end

  defp rank_drafts_by_type(product_id, content_type, top_n, scoreboard_context) do
    drafts =
      ContentGeneration.list_drafts_by_type(product_id, content_type)
      |> Enum.filter(fn d -> d.status == "draft" end)

    cond do
      drafts == [] ->
        Logger.info("No drafts to rank for #{content_type}")
        :ok

      no_provider_configured?() ->
        Logger.warning(
          "LLM unavailable: neither Anthropic nor Gemini is configured; skipping ranking for #{content_type}"
        )

        :ok

      true ->
        score_and_promote(drafts, top_n, content_type, scoreboard_context)
    end
  end

  defp score_and_promote(drafts, top_n, content_type, scoreboard_context) do
    case score_all(drafts, scoreboard_context) do
      :ok ->
        promote_top_n(drafts, top_n, content_type)
        :ok

      {:error, _} = err ->
        err
    end
  end

  defp score_all(drafts, scoreboard_context) do
    Enum.reduce_while(drafts, :ok, fn draft, _acc ->
      case score_draft_with_all_models(draft, scoreboard_context) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp score_draft_with_all_models(draft, scoreboard_context) do
    Enum.reduce_while(@models, :ok, fn model, _acc ->
      calibration = get_model_calibration(draft.product_id, model)

      case query_model_for_scores(draft, model, calibration, scoreboard_context) do
        {:ok, scores} ->
          upsert_score(draft, model, scores)
          {:cont, :ok}

        {:skip, reason} ->
          Logger.debug(
            "MultiModelRanker: skipped model #{model} for draft #{draft.id} - #{inspect(reason)}"
          )

          {:cont, :ok}

        {:error, _reason} = err ->
          {:halt, err}
      end
    end)
  end

  defp upsert_score(draft, model, scores) do
    attrs = %{
      draft_id: draft.id,
      model_name: model,
      accuracy_score: scores.accuracy,
      seo_score: scores.seo,
      eev_score: scores.eev,
      composite_score: scores.composite,
      critique: scores.critique
    }

    case ContentGeneration.get_score_for_draft_by_model(draft.id, model) do
      nil ->
        ContentGeneration.create_draft_score(attrs)

      existing ->
        existing
        |> DraftScore.changeset(attrs)
        |> ContentForge.Repo.update!()
    end
  end

  # --- provider routing ----------------------------------------------------

  defp query_model_for_scores(draft, model, calibration, scoreboard_context) do
    prompt = build_scoring_prompt(draft, model, calibration, scoreboard_context)

    case call_provider(model, prompt) do
      {:ok, text} -> parse_scores(text, model, draft)
      {:error, :not_configured} -> {:skip, :not_configured}
      {:error, {:transient, _, _}} = err -> err
      {:error, {:http_error, status, body}} -> permanent_skip(model, draft, status, body)
      {:error, {:unexpected_status, status, body}} -> permanent_skip(model, draft, status, body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp call_provider("claude", prompt),
    do: complete_text(Anthropic.complete(prompt, system: scoring_system_prompt()))

  defp call_provider("gemini", prompt),
    do: complete_text(Gemini.complete(prompt, system: scoring_system_prompt()))

  defp complete_text({:ok, %{text: text}}), do: {:ok, text}
  defp complete_text({:error, _} = err), do: err

  defp permanent_skip(model, draft, status, body) do
    Logger.error(
      "MultiModelRanker: permanent error from #{model} for draft #{draft.id} - HTTP #{status} #{inspect(body)}"
    )

    {:skip, {:http_error, status}}
  end

  # --- JSON parsing --------------------------------------------------------

  defp parse_scores(text, model, draft) do
    with {:ok, json} <- extract_json(text),
         %{"accuracy" => a, "seo" => s, "eev" => e, "critique" => c} <- json,
         true <- valid_score?(a) and valid_score?(s) and valid_score?(e) do
      acc = to_float(a)
      seo = to_float(s)
      eev = to_float(e)

      {:ok,
       %{
         accuracy: acc,
         seo: seo,
         eev: eev,
         composite: (acc + seo + eev) / 3,
         critique: to_string(c)
       }}
    else
      _ ->
        Logger.error(
          "MultiModelRanker: could not parse scoring response from #{model} for draft #{draft.id}: #{inspect(text)}"
        )

        {:skip, :malformed}
    end
  end

  defp extract_json(text) when is_binary(text) do
    trimmed = String.trim(text)

    case JSON.decode(trimmed) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> try_fenced(trimmed)
    end
  end

  defp extract_json(_), do: :error

  defp try_fenced(text) do
    case Regex.run(~r/```(?:json)?\s*(\{.*?\})\s*```/s, text) do
      [_, inner] ->
        case JSON.decode(inner) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp valid_score?(n) when is_number(n) and n >= 0 and n <= 10, do: true
  defp valid_score?(_), do: false

  defp to_float(n) when is_integer(n), do: n * 1.0
  defp to_float(n) when is_float(n), do: n

  # --- prompts -------------------------------------------------------------

  defp scoring_system_prompt do
    """
    You are an expert content critic. Given a draft plus its brief and
    performance context, score the draft on three dimensions: accuracy
    (0-10), SEO relevance (0-10), and entertainment/education value
    (EEV, 0-10), and write a short critique. Respond with a JSON object
    and nothing else, in exactly this shape:

    {
      "accuracy": <number 0-10>,
      "seo": <number 0-10>,
      "eev": <number 0-10>,
      "critique": "<short critique text>"
    }
    """
  end

  defp build_scoring_prompt(draft, model, calibration, scoreboard_context) do
    """
    Draft: #{draft.content}
    Platform: #{draft.platform}
    Content type: #{draft.content_type}
    Angle: #{draft.angle}

    Scoring provider: #{model}
    Your calibration: #{inspect(calibration)}

    Performance context:
    - Top performing angles: #{inspect(scoreboard_context.top_angles)}
    - Top performing formats: #{inspect(scoreboard_context.top_formats)}
    - Average engagement: #{scoreboard_context.avg_engagement}

    Score on:
    - Accuracy (0-10): alignment with the product and brief.
    - SEO (0-10): discoverability. For blog content, downgrade if any
      of the following are missing: AI summary nugget (<=200 char
      factual block at top); FAQ schema or FAQ section; at least three
      statistics or data points; no banned AI filler phrases (delve,
      comprehensive guide, in today's digital landscape, it's worth
      noting, navigate the complexities, etc.). Cap the SEO score at
      6 when a required element is missing.
    - EEV (0-10): entertainment or education value. For blog content,
      downgrade when an original research block, fast-scan elements
      (table, bold facts, bullet list), a direct lead (not a vague
      opener), or external citations are absent. Cap EEV at 6 when an
      element is missing.

    Return only the JSON object defined in the system prompt.
    """
  end

  # --- config + context placeholders --------------------------------------

  defp no_provider_configured? do
    Anthropic.status() == :not_configured and Gemini.status() == :not_configured
  end

  defp get_model_calibration(_product_id, _model_name) do
    # Placeholder - would query model_calibration when Phase 7 is done
    %{avg_score_delta: 0, sample_count: 0}
  end

  defp build_scoreboard_context(_product_id) do
    # Placeholder - would query content_scoreboard when Phase 7 is done
    %{
      top_angles: ["educational", "humor"],
      top_formats: ["how_to", "listicle"],
      avg_engagement: 0.0,
      recent_winners: [],
      recent_losers: []
    }
  end

  # --- promotion -----------------------------------------------------------

  defp promote_top_n(drafts, top_n, _content_type) do
    drafts_with_scores =
      drafts
      |> Enum.map(fn draft ->
        composite = ContentGeneration.compute_composite_score(draft.id)
        {draft, composite}
      end)
      |> Enum.filter(fn {_draft, composite} -> is_number(composite) end)
      |> Enum.sort_by(fn {_draft, score} -> score end, :desc)
      |> Enum.take(top_n)

    Enum.each(drafts_with_scores, fn {draft, score} ->
      ContentGeneration.update_draft_status(draft, "ranked")
      Logger.info("Promoted draft #{draft.id} to ranked (score: #{score})")
    end)

    # Archive previously-ranked drafts that did not make the top N.
    Enum.each(drafts, fn draft ->
      still_ranked? = Enum.any?(drafts_with_scores, fn {d, _} -> d.id == draft.id end)

      if not still_ranked? and draft.status == "ranked" do
        ContentGeneration.update_draft_status(draft, "archived")
      end
    end)

    {:ok, length(drafts_with_scores)}
  end
end
