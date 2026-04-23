defmodule ContentForge.Jobs.ContentBriefGenerator do
  @moduledoc """
  Oban job that generates or rewrites a content brief for a product.

  On first run the job sends a prompt built from the product's snapshot and
  competitor intelligence to `ContentForge.LLM.Anthropic.complete/2`; the
  completion text becomes the brief body and the actual model id returned
  by the API is recorded on the brief record.

  On subsequent runs (when performance data is available) it rewrites the
  brief with the previous brief and the performance summary in the prompt.

  When the LLM is not configured on this deployment the job logs
  `LLM unavailable`, returns `{:ok, :skipped}`, and does not create a
  brief record: no placeholder or templated text ever reaches the
  database. Transient errors propagate as `{:error, _}` so Oban retries;
  permanent errors cancel the job so retries do not spin against
  unchanged input.
  """
  use Oban.Worker, queue: :content_generation, max_attempts: 3
  require Logger

  alias ContentForge.{ContentGeneration, Products}
  alias ContentForge.LLM.BriefSynthesizer

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"product_id" => product_id, "force_rewrite" => force_rewrite}}) do
    product = Products.get_product!(product_id)

    if is_nil(product.voice_profile) do
      Logger.warning("Product #{product_id} has no voice profile, skipping brief generation")
      {:cancel, "Product has no voice profile"}
    else
      generate_or_rewrite_brief(product, force_rewrite || false)
    end
  end

  def perform(%Oban.Job{args: %{"product_id" => product_id}}) do
    perform(%Oban.Job{args: %{"product_id" => product_id, "force_rewrite" => false}})
  end

  defp generate_or_rewrite_brief(product, force_rewrite) do
    snapshot = Products.get_latest_snapshot_for_product(product.id, "full")
    competitor_intel = Products.get_latest_competitor_intel_for_product(product.id)

    existing_brief = ContentGeneration.get_latest_content_brief_for_product(product.id)

    existing_brief
    |> route(force_rewrite)
    |> run(product, snapshot, competitor_intel, existing_brief)
  end

  defp route(nil, _force), do: :initial
  defp route(_brief, true), do: :rewrite
  defp route(_brief, _force), do: :short_circuit

  defp run(:short_circuit, product, _snapshot, _intel, existing_brief) do
    Logger.info(
      "Content brief already exists for product #{product.id}, skipping initial generation"
    )

    {:ok, existing_brief}
  end

  defp run(:initial, product, snapshot, competitor_intel, _existing),
    do: generate_initial_brief(product, snapshot, competitor_intel)

  defp run(:rewrite, product, snapshot, competitor_intel, existing_brief),
    do: rewrite_brief_with_performance(product, existing_brief, snapshot, competitor_intel)

  defp generate_initial_brief(product, snapshot, competitor_intel) do
    context = build_brief_context(product, snapshot, competitor_intel, nil)

    context
    |> brief_user_prompt()
    |> call_llm(brief_system_prompt())
    |> handle_initial_llm_result(product, snapshot, competitor_intel)
  end

  defp rewrite_brief_with_performance(product, existing_brief, snapshot, competitor_intel) do
    performance_summary = %{}

    context = build_brief_context(product, snapshot, competitor_intel, performance_summary)

    context
    |> rewrite_user_prompt(existing_brief.content)
    |> call_llm(brief_system_prompt())
    |> handle_rewrite_llm_result(product, existing_brief, performance_summary)
  end

  # --- LLM result handling --------------------------------------------------

  defp handle_initial_llm_result({:ok, text, model}, product, snapshot, competitor_intel) do
    {:ok, brief} =
      ContentGeneration.create_content_brief(%{
        product_id: product.id,
        version: 1,
        content: text,
        snapshot_id: snapshot && snapshot.id,
        competitor_intel_id: competitor_intel && competitor_intel.id,
        model_used: model
      })

    Logger.info(
      "ContentBriefGenerator: created initial content brief v1 for product #{product.id} via #{model}"
    )

    {:ok, brief}
  end

  defp handle_initial_llm_result({:error, err}, product, _snapshot, _competitor_intel) do
    handle_llm_error(err, product.id)
  end

  defp handle_rewrite_llm_result({:ok, text, model}, product, existing_brief, performance_summary) do
    {:ok, new_brief} =
      ContentGeneration.create_new_brief_version(
        existing_brief,
        text,
        performance_summary,
        "Performance-based rewrite",
        model_used: model
      )

    Logger.info(
      "ContentBriefGenerator: created content brief v#{new_brief.version} for product #{product.id} via #{model}"
    )

    {:ok, new_brief}
  end

  defp handle_rewrite_llm_result({:error, err}, product, _existing_brief, _performance_summary) do
    handle_llm_error(err, product.id)
  end

  defp handle_llm_error(:not_configured, product_id) do
    Logger.warning(
      "ContentBriefGenerator: LLM unavailable; skipping brief for product #{product_id}"
    )

    {:ok, :skipped}
  end

  defp handle_llm_error({:transient, _, _} = reason, product_id) do
    Logger.warning(
      "ContentBriefGenerator: transient LLM error for product #{product_id}; Oban will retry (#{inspect(reason)})"
    )

    {:error, reason}
  end

  defp handle_llm_error({:http_error, status, body}, product_id) do
    Logger.error(
      "ContentBriefGenerator: permanent LLM error #{status} for product #{product_id}: #{inspect(body)}"
    )

    {:cancel, "LLM rejected brief request (HTTP #{status})"}
  end

  defp handle_llm_error({:unexpected_status, status, _body}, product_id) do
    Logger.error(
      "ContentBriefGenerator: LLM returned unexpected HTTP status #{status} for product #{product_id}"
    )

    {:cancel, "LLM returned unexpected HTTP status #{status}"}
  end

  defp handle_llm_error(reason, product_id) do
    Logger.error(
      "ContentBriefGenerator: unexpected LLM error for product #{product_id}: #{inspect(reason)}"
    )

    {:error, reason}
  end

  # --- LLM call wrapper -----------------------------------------------------

  defp call_llm(user_prompt, system_prompt) do
    BriefSynthesizer.generate(user_prompt, system_prompt)
  end

  # --- context + prompts ----------------------------------------------------

  defp build_brief_context(product, snapshot, competitor_intel, performance_summary) do
    %{
      product_name: product.name,
      voice_profile: product.voice_profile,
      repo_url: product.repo_url,
      site_url: product.site_url,
      snapshot_content: snapshot && snapshot.content,
      competitor_intel_content: competitor_intel && competitor_intel.summary,
      performance_summary: performance_summary || %{}
    }
  end

  defp brief_system_prompt do
    """
    You are an expert content strategist for a SaaS product team. Produce a
    concise, actionable content brief in Markdown that will steer future
    content generation. The brief must cover: voice profile, target
    audience, content pillars, required angles (educational, entertaining,
    problem_aware, social_proof, testimonial, and at least one humor
    angle), platform-specific guidelines for Twitter/X, LinkedIn, Reddit,
    and blog, and key themes for this cycle.
    """
  end

  defp brief_user_prompt(context) do
    """
    Product: #{context.product_name}
    Voice profile: #{context.voice_profile}
    Repository: #{context.repo_url || "N/A"}
    Site: #{context.site_url || "N/A"}

    Product snapshot:
    #{context.snapshot_content || "(no snapshot available)"}

    Competitor intelligence:
    #{context.competitor_intel_content || "(no competitor intel available)"}

    Write the content brief.
    """
  end

  defp rewrite_user_prompt(context, previous_brief) do
    """
    Product: #{context.product_name}
    Voice profile: #{context.voice_profile}

    Previous brief:
    #{previous_brief}

    Performance summary:
    #{inspect(context.performance_summary)}

    Competitor intelligence:
    #{context.competitor_intel_content || "(no competitor intel available)"}

    Rewrite the brief, identifying which angles and formats are working,
    which are underperforming, and what to try next. Keep the same
    structure.
    """
  end
end
