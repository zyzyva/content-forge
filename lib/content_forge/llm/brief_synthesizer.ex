defmodule ContentForge.LLM.BriefSynthesizer do
  @moduledoc """
  Orchestrates multi-provider brief generation for
  `ContentForge.Jobs.ContentBriefGenerator`.

  When both Anthropic and Gemini are configured, both providers are
  queried in parallel and their drafts are synthesised via one final
  Anthropic call that produces the combined brief. This satisfies the
  Feature 3 Stage 1 acceptance criterion that brief generation queries
  at least two smart models.

  When only one provider is configured, the brief is generated from
  that provider alone with no synthesis step. When neither is
  configured, the caller's skip path fires (no brief record is written).

  When one provider succeeds and the other errors, the successful
  provider's draft is used as the brief content with a note in the
  returned `model_descriptor` string; no error escalates as long as at
  least one draft succeeded. When both providers fail, the transient
  error (if any) is propagated so Oban retries; otherwise the permanent
  error is propagated so the job cancels.
  """

  alias ContentForge.LLM.Anthropic
  alias ContentForge.LLM.Gemini

  require Logger

  @provider_timeout_ms 65_000

  @type outcome ::
          {:ok, text :: String.t(), model_descriptor :: String.t()}
          | {:error, :not_configured}
          | {:error, any()}

  @doc """
  Generates a brief using whichever providers are configured.

  Returns `{:ok, text, model_descriptor}` on success where
  `model_descriptor` is a string that describes which provider or
  providers produced the text.
  """
  @spec generate(String.t(), String.t()) :: outcome()
  def generate(user_prompt, system_prompt) do
    dispatch({Anthropic.status(), Gemini.status()}, user_prompt, system_prompt)
  end

  # --- dispatch ------------------------------------------------------------

  defp dispatch({:not_configured, :not_configured}, _user, _system),
    do: {:error, :not_configured}

  defp dispatch({:ok, :not_configured}, user, system),
    do: single_provider(:anthropic, user, system)

  defp dispatch({:not_configured, :ok}, user, system),
    do: single_provider(:gemini, user, system)

  defp dispatch({:ok, :ok}, user, system), do: dual_provider(user, system)

  # --- single-provider path ------------------------------------------------

  defp single_provider(:anthropic, user, system) do
    case Anthropic.complete(user, system: system) do
      {:ok, %{text: text, model: model}} -> {:ok, text, "anthropic:#{model}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp single_provider(:gemini, user, system) do
    case Gemini.complete(user, system: system) do
      {:ok, %{text: text, model: model}} -> {:ok, text, "gemini:#{model}"}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- dual-provider path --------------------------------------------------

  defp dual_provider(user, system) do
    anthropic_task = Task.async(fn -> Anthropic.complete(user, system: system) end)
    gemini_task = Task.async(fn -> Gemini.complete(user, system: system) end)

    a_result = Task.await(anthropic_task, @provider_timeout_ms)
    g_result = Task.await(gemini_task, @provider_timeout_ms)

    combine(a_result, g_result, user, system)
  end

  defp combine({:ok, a}, {:ok, g}, _user, system), do: synthesize(a, g, system)

  defp combine({:ok, a}, {:error, reason}, _user, _system) do
    Logger.warning(
      "BriefSynthesizer: Gemini errored; falling back to Anthropic only (#{inspect(reason)})"
    )

    {:ok, a.text, "anthropic:#{a.model} (gemini unavailable)"}
  end

  defp combine({:error, reason}, {:ok, g}, _user, _system) do
    Logger.warning(
      "BriefSynthesizer: Anthropic errored; falling back to Gemini only (#{inspect(reason)})"
    )

    {:ok, g.text, "gemini:#{g.model} (anthropic unavailable)"}
  end

  defp combine({:error, a_reason}, {:error, g_reason}, _user, _system) do
    Logger.error(
      "BriefSynthesizer: both providers failed: anthropic=#{inspect(a_reason)}, gemini=#{inspect(g_reason)}"
    )

    {:error, prefer_transient(a_reason, g_reason)}
  end

  # --- synthesis step ------------------------------------------------------

  defp synthesize(a, g, _system) do
    case Anthropic.complete(synthesis_user_prompt(a.text, g.text),
           system: synthesis_system_prompt()
         ) do
      {:ok, %{text: text, model: model}} ->
        descriptor =
          "synthesis: anthropic:#{a.model} + gemini:#{g.model} -> anthropic:#{model}"

        {:ok, text, descriptor}

      {:error, reason} ->
        Logger.error(
          "BriefSynthesizer: synthesis step failed after both drafts succeeded: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp synthesis_system_prompt do
    """
    You are an expert content strategist. You are given two independently
    produced content briefs for the same product. Synthesise them into a
    single coherent brief in Markdown, taking the strongest angles and
    insights from each. Preserve the required structural sections (voice
    profile, target audience, content pillars, content angles including
    at least one humor angle, platform-specific guidelines, and key
    themes for this cycle) and drop duplicate or weaker material.
    """
  end

  defp synthesis_user_prompt(draft_a, draft_b) do
    """
    Draft A (Anthropic):
    #{draft_a}

    ---

    Draft B (Gemini):
    #{draft_b}

    ---

    Synthesise these two drafts into a single content brief.
    """
  end

  # --- error preference ----------------------------------------------------

  # When both providers fail we prefer to return a transient error so
  # Oban retries. Only when every provider's error is permanent does a
  # permanent error bubble up and cause the job to cancel.

  defp prefer_transient({:transient, _, _} = transient, _), do: transient
  defp prefer_transient(_, {:transient, _, _} = transient), do: transient
  defp prefer_transient(reason, _), do: reason
end
