defmodule ContentForge.CompetitorIntelSynthesizer.LLMAdapter do
  @moduledoc """
  LLM-backed implementation of the `summarize/1` contract that
  `ContentForge.Jobs.CompetitorIntelSynthesizer` dispatches to via the
  `:intel_model` config.

  Given a list of `%ContentForge.Products.CompetitorPost{}` structs, the
  adapter asks `ContentForge.LLM.Anthropic.complete/2` to return a
  structured JSON object matching the `CompetitorIntel` schema shape:

      %{
        summary: binary(),
        trending_topics: [binary()],
        winning_formats: [binary()],
        effective_hooks: [binary()]
      }

  Parsing mirrors the `MultiModelRanker` pattern: `JSON.decode` first,
  then a fenced-block regex fallback for replies that wrap JSON in a
  ` ```json ... ``` ` block. Malformed or missing-field responses are
  rejected with `{:error, :malformed_response}` - no fabricated
  fallback ever reaches the database.

  Downgrade semantics:

    * `{:error, :not_configured}` from the LLM passes through unchanged.
      The synthesizer already discards on that return.
    * Transient HTTP errors (5xx, 429, timeout, network) propagate so
      Oban retries the whole job.
    * Permanent HTTP errors (4xx, unexpected_status) propagate so the
      caller can cancel or surface the failure.
    * Empty post list returns `{:error, :no_posts}` without issuing any
      HTTP request. In practice the synthesizer handles the empty case
      before calling the adapter; this is a defensive guard only.
  """

  alias ContentForge.LLM.Anthropic
  alias ContentForge.Products.CompetitorPost

  require Logger

  @type intel :: %{
          summary: String.t(),
          trending_topics: [String.t()],
          winning_formats: [String.t()],
          effective_hooks: [String.t()]
        }

  @doc "Synthesises competitor intel from a list of top-performing posts."
  @spec summarize([CompetitorPost.t()]) :: {:ok, intel()} | {:error, term()}
  def summarize([]), do: {:error, :no_posts}

  def summarize(posts) when is_list(posts) do
    user_prompt = build_user_prompt(posts)

    case Anthropic.complete(user_prompt, system: system_prompt()) do
      {:ok, %{text: text}} -> parse(text)
      {:error, _} = err -> err
    end
  end

  # --- prompts -------------------------------------------------------------

  defp system_prompt do
    """
    You are a competitive-content analyst. Given a ranked list of top
    competitor posts (with engagement numbers), synthesise a compact
    intel brief that downstream content generation can bias toward.
    Respond with a JSON object and nothing else, in exactly this shape:

    {
      "summary": "<2-4 sentence plain-English synthesis>",
      "trending_topics": ["<topic>", "<topic>", ...],
      "winning_formats": ["<format>", "<format>", ...],
      "effective_hooks": ["<hook>", "<hook>", ...]
    }

    All four fields are required. The three array fields must each be a
    JSON array of short strings.
    """
  end

  defp build_user_prompt(posts) do
    posts_block =
      posts
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {post, idx} -> format_post(post, idx) end)

    """
    Top competitor posts (ranked by engagement):

    #{posts_block}

    Produce the intel brief as described in the system prompt.
    """
  end

  defp format_post(%CompetitorPost{} = post, idx) do
    """
    #{idx}. [likes=#{post.likes_count || 0}, comments=#{post.comments_count || 0}, shares=#{post.shares_count || 0}, score=#{post.engagement_score || 0.0}]
    #{post.content}
    """
  end

  # --- JSON parsing --------------------------------------------------------

  defp parse(text) when is_binary(text) do
    with {:ok, json} <- extract_json(text),
         {:ok, intel} <- coerce_intel(json) do
      {:ok, intel}
    else
      _ ->
        Logger.error(
          "CompetitorIntelSynthesizer.LLMAdapter: could not parse LLM reply: #{inspect(text)}"
        )

        {:error, :malformed_response}
    end
  end

  defp parse(_other), do: {:error, :malformed_response}

  defp extract_json(text) do
    trimmed = String.trim(text)

    case JSON.decode(trimmed) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> try_fenced(trimmed)
    end
  end

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

  defp coerce_intel(%{
         "summary" => summary,
         "trending_topics" => topics,
         "winning_formats" => formats,
         "effective_hooks" => hooks
       })
       when is_binary(summary) and summary != "" do
    with {:ok, topics} <- coerce_string_list(topics),
         {:ok, formats} <- coerce_string_list(formats),
         {:ok, hooks} <- coerce_string_list(hooks) do
      {:ok,
       %{
         summary: summary,
         trending_topics: topics,
         winning_formats: formats,
         effective_hooks: hooks
       }}
    end
  end

  defp coerce_intel(_other), do: :error

  defp coerce_string_list(values) when is_list(values) do
    if Enum.all?(values, &is_binary/1), do: {:ok, values}, else: :error
  end

  defp coerce_string_list(_), do: :error
end
