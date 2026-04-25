defmodule ContentForge.CompetitorIntelSynthesizer.LLMAdapter do
  @moduledoc """
  LLM-backed implementation of the `summarize/1` contract that
  `ContentForge.Jobs.CompetitorIntelSynthesizer` dispatches to via the
  `:intel_model` config.

  Given a list of `%ContentForge.Products.CompetitorPost{}` structs
  (with `:comments` preloaded when available), the adapter asks
  `ContentForge.LLM.Anthropic.complete/2` to return a structured JSON
  object matching the `CompetitorIntel` schema shape:

      %{
        summary: binary(),
        trending_topics: [binary()],
        winning_formats: [binary()],
        effective_hooks: [binary()],
        audience_signals: [binary()]
      }

  Phase 17.4 made the prompt comment-aware: each post block carries its
  top-50-by-likes comment thread (when comments are loaded), and the
  system prompt asks the LLM to extract `audience_signals` (recurring
  objections, questions, emotional reactions, consensus tropes).

  Parsing mirrors the `MultiModelRanker` pattern: `JSON.decode` first,
  then a fenced-block regex fallback for replies that wrap JSON in a
  ` ```json ... ``` ` block. Malformed or missing-field responses are
  rejected with `{:error, :malformed_response}` - no fabricated
  fallback ever reaches the database.

  Downgrade semantics:

    * `{:error, :not_configured}` from the LLM passes through unchanged.
      The synthesizer routes this to the without-key `pending_manual`
      path defined in Phase 17.4.
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
  alias ContentForge.Products.CompetitorPostComment

  require Logger

  @type intel :: %{
          summary: String.t(),
          trending_topics: [String.t()],
          winning_formats: [String.t()],
          effective_hooks: [String.t()],
          audience_signals: [String.t()]
        }

  @comments_per_post 50

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
    competitor posts (with engagement numbers, plus their top reply
    threads when available), synthesise a compact intel brief that
    downstream content generation can bias toward. Respond with a JSON
    object and nothing else, in exactly this shape:

    {
      "summary": "<2-4 sentence plain-English synthesis>",
      "trending_topics": ["<topic>", "<topic>", ...],
      "winning_formats": ["<format>", "<format>", ...],
      "effective_hooks": ["<hook>", "<hook>", ...],
      "audience_signals": ["<signal>", "<signal>", ...]
    }

    All five fields are required. The four array fields must each be a
    JSON array of short strings.

    `audience_signals` should capture recurring objections, questions,
    emotional reactions, and consensus tropes that appear in the
    comment threads. When no comments are present the array may be
    empty (`[]`); never invent signals from the post body alone.
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
    header =
      "#{idx}. [likes=#{post.likes_count || 0}, comments=#{post.comments_count || 0}, shares=#{post.shares_count || 0}, score=#{post.engagement_score || 0.0}]"

    body = post.content || ""

    """
    #{header}
    #{body}
    #{format_comments(post)}
    """
  end

  defp format_comments(%CompetitorPost{comments: comments}) when is_list(comments) and comments != [] do
    top =
      comments
      |> Enum.sort_by(&(&1.likes_count || 0), :desc)
      |> Enum.take(@comments_per_post)

    lines = Enum.map(top, &format_comment/1)
    "Top comments (by likes):\n" <> Enum.join(lines, "\n")
  end

  defp format_comments(_post), do: ""

  defp format_comment(%CompetitorPostComment{} = c) do
    handle = c.author_handle || "anonymous"
    likes = c.likes_count || 0
    text = (c.text || "") |> String.trim()
    "  - @#{handle} (#{likes} likes): #{text}"
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
       } = json)
       when is_binary(summary) and summary != "" do
    with {:ok, topics} <- coerce_string_list(topics),
         {:ok, formats} <- coerce_string_list(formats),
         {:ok, hooks} <- coerce_string_list(hooks),
         {:ok, signals} <- coerce_optional_string_list(json["audience_signals"]) do
      {:ok,
       %{
         summary: summary,
         trending_topics: topics,
         winning_formats: formats,
         effective_hooks: hooks,
         audience_signals: signals
       }}
    end
  end

  defp coerce_intel(_other), do: :error

  defp coerce_string_list(values) when is_list(values) do
    if Enum.all?(values, &is_binary/1), do: {:ok, values}, else: :error
  end

  defp coerce_string_list(_), do: :error

  # `audience_signals` is required in the system prompt but the
  # parser tolerates an absent field by defaulting to []; older
  # LLM responses (or models that ignore the new requirement)
  # still produce a valid intel row rather than failing the whole
  # synthesis.
  defp coerce_optional_string_list(nil), do: {:ok, []}
  defp coerce_optional_string_list(values), do: coerce_string_list(values)
end
