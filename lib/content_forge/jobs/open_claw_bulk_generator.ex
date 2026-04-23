defmodule ContentForge.Jobs.OpenClawBulkGenerator do
  @moduledoc """
  Oban job that generates bulk content variants for a product
  via `ContentForge.LLM.Anthropic`.

  Phase 11.2L renamed the semantics - the module still carries
  the `OpenClawBulkGenerator` name for backwards compatibility,
  but it dispatches through the LLM client rather than an
  OpenClaw HTTP endpoint. OpenClaw is locally hosted and
  turn-oriented; Anthropic is already configured for batch,
  structured-JSON responses and is what the rest of the
  generation pipeline uses (see `ContentBriefGenerator`,
  `AssetBundleDraftGenerator`, `MultiModelRanker`).

  Three LLM calls, one per content family:

    1. Social posts - one call returning per-platform arrays of
       variants across twitter / linkedin / reddit / facebook /
       instagram.
    2. Blog drafts - one call returning angle-labeled variants.
    3. Video scripts - one call returning angle-labeled variants.

  Each variant becomes a `Draft` with `generating_model` set to
  the actual Anthropic model name returned in the response (not
  a hardcoded "openclaw" marker). Blog drafts flow through
  `ContentGeneration.create_draft/1` individually so the Phase
  12.1 nugget validator + 12.2a SEO checklist hooks run on each.

  Humor-angle guarantee: every prompt explicitly requires at
  least one variant labeled `angle: "humor"` per family.

  Failure modes:

    * `{:error, :not_configured}` on Anthropic - log + return
      `{:ok, :skipped}`, zero drafts created.
    * Malformed JSON / missing expected keys - `{:cancel,
      "malformed LLM output"}`. Never fabricates content.
    * `{:error, {:transient, _, _}}` - return the error so Oban
      retries.
    * `{:error, {:http_error, status, _}}` / `{:unexpected_status,
      _, _}` - `{:cancel, reason}`.
  """
  use Oban.Worker, queue: :content_generation, max_attempts: 3
  require Logger

  alias ContentForge.ContentGeneration
  alias ContentForge.LLM.Anthropic
  alias ContentForge.Products

  @default_social_variants 20
  @default_blog_drafts 5
  @default_video_scripts 10

  @social_platforms ~w(twitter linkedin reddit facebook instagram)
  @social_angles ~w(educational entertaining problem_aware social_proof humor testimonial case_study how_to)
  @blog_angles ~w(educational how_to listicle case_study problem_aware humor)
  @video_angles ~w(educational problem_aware demo testimonial humor how_to)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"product_id" => product_id, "options" => options}}) do
    product = Products.get_product!(product_id)

    if is_nil(product.voice_profile) do
      {:cancel, "Product has no voice profile"}
    else
      generate_content(product, options || %{})
    end
  end

  def perform(%Oban.Job{args: %{"product_id" => product_id}}) do
    perform(%Oban.Job{args: %{"product_id" => product_id, "options" => %{}}})
  end

  defp generate_content(product, options) do
    brief = ContentGeneration.get_latest_content_brief_for_product(product.id)

    cond do
      is_nil(brief) ->
        Logger.warning("OpenClawBulkGenerator: no content brief for product #{product.id}")
        {:cancel, "No content brief found"}

      Anthropic.status() == :not_configured ->
        Logger.warning(
          "OpenClawBulkGenerator: LLM unavailable for bulk generation; skipping with zero drafts"
        )

        {:ok, :skipped}

      true ->
        do_generate(product, brief, options)
    end
  end

  defp do_generate(product, brief, options) do
    social_count = Map.get(options, "social_variants", @default_social_variants)
    blog_count = Map.get(options, "blog_drafts", @default_blog_drafts)
    video_count = Map.get(options, "video_scripts", @default_video_scripts)

    with {:ok, social} <- generate_social(product, brief, social_count),
         {:ok, blogs} <- generate_blogs(product, brief, blog_count),
         {:ok, videos} <- generate_videos(product, brief, video_count) do
      total = length(social) + length(blogs) + length(videos)

      Logger.info(
        "OpenClawBulkGenerator: created #{total} drafts for product #{product.id} (#{length(social)} social, #{length(blogs)} blog, #{length(videos)} video)"
      )

      {:ok, %{drafts_created: total}}
    else
      error -> classify_error(error)
    end
  end

  # --- social posts ----------------------------------------------------------

  defp generate_social(product, brief, count) do
    prompt = social_prompt(product, brief, count)

    with {:ok, %{text: text, model: model}} <- Anthropic.complete(prompt, system: system_prompt()),
         {:ok, payload} <- extract_json(text),
         {:ok, per_platform} <- Map.fetch(payload, "platforms") || {:error, :malformed_llm_output} do
      drafts =
        @social_platforms
        |> Enum.flat_map(fn platform ->
          variants = Map.get(per_platform, platform, [])
          persist_social_variants(product, brief, platform, variants, model)
        end)

      {:ok, drafts}
    end
  end

  defp social_prompt(product, brief, count) do
    """
    Generate social post variants for #{product.name}.

    Voice profile: #{product.voice_profile}

    Content brief:
    #{brief.content}

    Produce #{count} variants per platform across these platforms:
    #{Enum.join(@social_platforms, ", ")}

    Each variant is labeled with one of these angles:
    #{Enum.join(@social_angles, ", ")}

    At least one variant per platform MUST use angle "humor".

    BANNED PHRASES - never use:
    delve, comprehensive guide, in today's digital landscape, it's worth noting,
    as an AI, in conclusion it's clear, at the end of the day, in the ever-evolving,
    navigate the complexities.

    Respond with a single JSON object and nothing else, in exactly
    this shape (extra keys allowed but ignored):

        {
          "platforms": {
            "twitter":  [{"angle": "humor", "content": "..."}, ...],
            "linkedin": [{"angle": "educational", "content": "..."}, ...]
          }
        }

    Use specific numbers and data wherever possible. No fabricated metrics.
    """
  end

  defp persist_social_variants(product, brief, platform, variants, model)
       when is_list(variants) do
    descriptor = "anthropic:#{model}"

    variants
    |> Enum.filter(&valid_variant?/1)
    |> Enum.map(fn %{"angle" => angle, "content" => content} ->
      {:ok, draft} =
        ContentGeneration.create_draft(%{
          product_id: product.id,
          content_brief_id: brief.id,
          content: content,
          platform: platform,
          content_type: "post",
          angle: normalize_angle(angle, @social_angles),
          generating_model: descriptor,
          status: "draft"
        })

      draft
    end)
  end

  defp persist_social_variants(_product, _brief, _platform, _other, _model), do: []

  # --- blog drafts -----------------------------------------------------------

  defp generate_blogs(product, brief, count) do
    prompt = blog_prompt(product, brief, count)

    with {:ok, %{text: text, model: model}} <- Anthropic.complete(prompt, system: system_prompt()),
         {:ok, payload} <- extract_json(text),
         {:ok, variants} <- Map.fetch(payload, "variants") || {:error, :malformed_llm_output} do
      descriptor = "anthropic:#{model}"

      drafts =
        variants
        |> Enum.filter(&valid_variant?/1)
        |> Enum.map(fn %{"angle" => angle, "content" => content} ->
          {:ok, draft} =
            ContentGeneration.create_draft(%{
              product_id: product.id,
              content_brief_id: brief.id,
              content: content,
              platform: "blog",
              content_type: "blog",
              angle: normalize_angle(angle, @blog_angles),
              generating_model: descriptor,
              status: "draft"
            })

          draft
        end)

      {:ok, drafts}
    end
  end

  defp blog_prompt(product, brief, count) do
    """
    Generate #{count} blog article variants for #{product.name}.

    Voice profile: #{product.voice_profile}

    Content brief:
    #{brief.content}

    Each variant is labeled with one of these angles:
    #{Enum.join(@blog_angles, ", ")}

    At least one variant MUST use angle "humor".

    Every variant opens with an AI Summary Nugget as its first
    paragraph: 100-250 chars, at least 2 entity tokens (proper
    nouns or numbers), no hedging language ("sort of",
    "perhaps", "maybe", "probably", "arguably", "somewhat"),
    no opening pronouns ("This", "That", "It", "They",
    "These", "Those", "Here", "There"). The first word must be
    an entity.

    Respond with a single JSON object:

        {
          "variants": [
            {"angle": "how_to", "content": "# Title\\n\\nNugget paragraph...\\n\\n..."},
            {"angle": "humor",  "content": "..."}
          ]
        }

    BANNED PHRASES - never use:
    delve, comprehensive guide, in today's digital landscape, it's worth noting,
    as an AI, in conclusion it's clear, at the end of the day, in the ever-evolving,
    navigate the complexities.
    """
  end

  # --- video scripts ---------------------------------------------------------

  defp generate_videos(product, brief, count) do
    prompt = video_prompt(product, brief, count)

    with {:ok, %{text: text, model: model}} <- Anthropic.complete(prompt, system: system_prompt()),
         {:ok, payload} <- extract_json(text),
         {:ok, variants} <- Map.fetch(payload, "variants") || {:error, :malformed_llm_output} do
      descriptor = "anthropic:#{model}"

      drafts =
        variants
        |> Enum.filter(&valid_variant?/1)
        |> Enum.map(fn %{"angle" => angle, "content" => content} ->
          {:ok, draft} =
            ContentGeneration.create_draft(%{
              product_id: product.id,
              content_brief_id: brief.id,
              content: content,
              platform: "youtube",
              content_type: "video_script",
              angle: normalize_angle(angle, @video_angles),
              generating_model: descriptor,
              status: "draft"
            })

          draft
        end)

      {:ok, drafts}
    end
  end

  defp video_prompt(product, brief, count) do
    """
    Generate #{count} short-form video scripts for #{product.name}.

    Voice profile: #{product.voice_profile}

    Content brief:
    #{brief.content}

    Each script is labeled with one of these angles:
    #{Enum.join(@video_angles, ", ")}

    At least one script MUST use angle "humor".

    Format each script with Hook / Problem / Solution / CTA
    sections and time markers (0:00-0:15 hook, etc.). Keep
    total length around 2-3 minutes.

    Respond with a single JSON object:

        {
          "variants": [
            {"angle": "educational", "content": "Script text..."},
            {"angle": "humor",       "content": "..."}
          ]
        }

    BANNED PHRASES - never use:
    delve, comprehensive guide, in today's digital landscape, it's worth noting,
    as an AI, in conclusion it's clear, at the end of the day, in the ever-evolving,
    navigate the complexities.
    """
  end

  # --- LLM plumbing ----------------------------------------------------------

  defp system_prompt do
    """
    You are a senior content strategist producing bulk variants
    for a specific product. Respond ONLY with the JSON structure
    requested - no preamble, no explanatory text. Every variant
    must ground in the supplied brief. Never fabricate metrics.
    """
  end

  defp extract_json(text) when is_binary(text) do
    trimmed = String.trim(text)

    case JSON.decode(trimmed) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> try_fenced(trimmed)
    end
  end

  defp extract_json(_), do: {:error, :malformed_llm_output}

  defp try_fenced(text) do
    case Regex.run(~r/```(?:json)?\s*(\{.*?\})\s*```/s, text) do
      [_, inner] ->
        case JSON.decode(inner) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
          _ -> {:error, :malformed_llm_output}
        end

      _ ->
        {:error, :malformed_llm_output}
    end
  end

  defp valid_variant?(%{"angle" => angle, "content" => content})
       when is_binary(angle) and is_binary(content) and content != "",
       do: true

  defp valid_variant?(_), do: false

  defp normalize_angle(angle, allowed) do
    if angle in allowed, do: angle, else: "educational"
  end

  # --- error classification --------------------------------------------------

  defp classify_error({:error, :not_configured}) do
    Logger.warning(
      "OpenClawBulkGenerator: LLM unavailable mid-generation; skipping with zero drafts"
    )

    {:ok, :skipped}
  end

  defp classify_error({:error, :malformed_llm_output}) do
    Logger.error("OpenClawBulkGenerator: malformed LLM output; cancelling")
    {:cancel, "malformed LLM output"}
  end

  defp classify_error({:error, {:transient, _, _} = reason}) do
    Logger.warning("OpenClawBulkGenerator: transient LLM error #{inspect(reason)}; retrying")
    {:error, reason}
  end

  defp classify_error({:error, {:http_error, status, body}}) do
    Logger.error("OpenClawBulkGenerator: permanent LLM error #{status}: #{inspect(body)}")
    {:cancel, "LLM rejected generation request (HTTP #{status})"}
  end

  defp classify_error({:error, {:unexpected_status, status, _body}}) do
    Logger.error("OpenClawBulkGenerator: unexpected LLM status #{status}")
    {:cancel, "LLM returned unexpected HTTP status #{status}"}
  end

  defp classify_error({:error, reason}) do
    Logger.error("OpenClawBulkGenerator: unexpected LLM error: #{inspect(reason)}")
    {:error, reason}
  end
end
