defmodule ContentForge.CompetitorScraper.ApifyAdapter do
  @moduledoc """
  Apify-backed implementation of the `fetch_posts/1` contract that
  `ContentForge.Jobs.CompetitorScraper` already dispatches to via the
  `:scraper_adapter` config.

  The adapter picks a per-platform Apify actor from configuration, runs
  it with the competitor account handle as input, polls the run until
  terminal, fetches the default dataset items, and normalises each item
  to the post-map shape the caller expects:

      %{
        post_id: binary(),
        content: binary(),
        post_url: binary(),
        likes_count: non_neg_integer(),
        comments_count: non_neg_integer(),
        shares_count: non_neg_integer(),
        views_count: non_neg_integer(),
        conversation_id: binary() | nil,
        posted_at: DateTime.t(),
        raw_data: map()
      }

  ## Actor ids chosen at 11.3a slice time

  These can be overridden in application config at any time. The
  defaults selected for the slice are widely-used Apify community
  scrapers; swap to paid or higher-fidelity actors by updating the
  `:actors` config map.

      %{
        "twitter"   => "kaitoeasyapi~twitter-x-data-tweet-scraper-pay-per-result-cheapest",
        "linkedin"  => "apify~linkedin-post-scraper",
        "reddit"    => "trudax~reddit-scraper",
        "facebook"  => "apify~facebook-pages-scraper",
        "instagram" => "apify~instagram-scraper",
        "youtube"   => "apify~youtube-scraper"
      }

  Phase 17.1 swapped the Twitter default from
  `apify~twitter-scraper` (broken) to the kaitoeasyapi
  pay-per-result scraper. Override per env via
  `APIFY_ACTOR_TWITTER`.

  If a platform has no actor mapping the adapter short-circuits with
  `{:error, :unsupported_platform}` and issues no HTTP request.

  ## Configuration

      config :content_forge, :apify,
        base_url: "https://api.apify.com",
        token: System.get_env("APIFY_TOKEN"),
        actors: %{...},
        poll_interval_ms: 3_000,
        poll_max_attempts: 60

  Missing token returns `{:error, :not_configured}` with zero HTTP.

  ## Authentication

  The Apify API accepts a Bearer token. Every outbound request sets
  `Authorization: Bearer <token>`; callers cannot omit it.

  ## Error classification

    * `{:error, :not_configured}` - token not configured
    * `{:error, :unsupported_platform}` - no actor mapped for platform
    * `{:error, {:transient, status, body}}` - 5xx or 429
    * `{:error, {:transient, :timeout, reason}}` - HTTP timeout
    * `{:error, {:transient, :network, reason}}` - network-layer error
    * `{:error, {:http_error, status, body}}` - other 4xx
    * `{:error, {:unexpected_status, status, body}}` - 3xx
    * `{:error, {:apify_run_failed, status}}` - terminal non-success run
    * `{:error, :apify_run_poll_timeout}` - poll exhausted attempts
    * `{:error, :apify_parse_failure}` - zero items normalised from dataset
    * `{:error, reason}` - anything else
  """

  require Logger

  alias ContentForge.Products.CompetitorAccount
  alias ContentForge.Products.CompetitorPost

  @config_app :content_forge
  @config_key :apify

  @default_base_url "https://api.apify.com"
  @default_poll_interval_ms 3_000
  @default_poll_max_attempts 60

  @terminal_success ~w(SUCCEEDED)
  @terminal_failure ~w(FAILED ABORTED TIMED-OUT TIMED_OUT)

  @doc "Returns `:ok` when an Apify token is configured, `:not_configured` otherwise."
  @spec status() :: :ok | :not_configured
  def status, do: status_from_token(fetch_token())

  @doc "Fetches recent posts for the given competitor account."
  @spec fetch_posts(CompetitorAccount.t()) :: {:ok, [map()]} | {:error, term()}
  def fetch_posts(%CompetitorAccount{} = account) do
    dispatch(account, fetch_token(), actor_for(account.platform))
  end

  @doc """
  Fetches comments on a competitor post by `conversation_id`.

  Phase 17.1 corpus enrichment: when a post crosses the viral
  threshold (`ContentForge.CompetitorResearch.viral?/2`), the
  scraper enqueues `ContentForge.Jobs.CompetitorCommentHarvester`
  which calls this function to pull the top-N replies.

  `limit` caps the number of comments at the source so we do
  not pay for thousands of low-resonance noise replies. Default
  matches `CompetitorResearch.max_comments_per_viral_post/0`.

  Returns `{:ok, [comment_map]}` where each `comment_map` is
  shaped for `Products.upsert_competitor_post_comment/1`.
  Returns the same `:not_configured` / `:unsupported_platform`
  / classified-error tuples as `fetch_posts/1`.
  """
  @spec fetch_comments(CompetitorPost.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch_comments(%CompetitorPost{} = post, opts \\ []) do
    limit = Keyword.get(opts, :limit, default_comment_limit())
    platform = Keyword.get(opts, :platform) || infer_platform(post)
    dispatch_comments(post, limit, fetch_token(), comment_actor_for(platform))
  end

  @doc """
  Phase 17.7 all-platforms metrics rewire: looks up engagement
  counts for a single published post by spinning up a one-shot
  scrape against the per-platform Apify actor.

  Returns:

      {:ok, %{
        "likes"    => non_neg_integer() | nil,
        "comments" => non_neg_integer() | nil,
        "shares"   => non_neg_integer() | nil,
        "views"    => non_neg_integer() | nil
      }}

  The map is intentionally platform-agnostic ("comments" not
  "replies", "shares" not "retweets") so MetricsPoller and the
  corrective loop can read engagement uniformly across platforms.
  Counts default to `nil` (not `0`) when the actor response does
  not include the field, so callers can distinguish "not measured"
  from "measured as zero" (matters for corrective-loop signal
  honesty).

  Per-platform dispatch:

    * `"twitter"`  -> kaitoeasyapi tweet-by-id actor, `startUrls`
    * `"linkedin"` -> apify linkedin-post-scraper, `urls`
    * `"facebook"` -> apify facebook posts scraper, `startUrls`
    * `"instagram"`-> apify instagram-scraper, `directUrls`
    * `"reddit"`   -> trudax reddit-scraper, `startUrls`
    * `"youtube"`  -> apify youtube-scraper, `startUrls`

  Per-platform actor selection: looks up `:metrics_actors` first
  (so a platform can use a different per-post actor than its
  handle-scraping actor without disturbing 17.1), then falls back
  to the `:actors` map populated by 17.1.

  Same error taxonomy as `fetch_posts/1`:

    * `{:error, :not_configured}` - no `APIFY_TOKEN`
    * `{:error, :unsupported_platform}` - actor not mapped for platform
    * `{:error, {:transient, status, body}}` / `{:error, {:http_error, status, body}}`
    * `{:error, {:apify_run_failed, status}}`
    * `{:error, :apify_run_poll_timeout}`
    * `{:error, :apify_parse_failure}` (zero items in dataset)
  """
  @spec fetch_metrics_for_post(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_metrics_for_post(platform, post_url)
      when is_binary(platform) and is_binary(post_url) do
    dispatch_metrics(platform, post_url, fetch_token(), metrics_actor_for(platform))
  end

  defp dispatch_metrics(_platform, _url, nil, _actor), do: {:error, :not_configured}
  defp dispatch_metrics(_platform, _url, "", _actor), do: {:error, :not_configured}
  defp dispatch_metrics(_platform, _url, _token, nil), do: {:error, :unsupported_platform}

  defp dispatch_metrics(platform, url, token, actor) do
    with {:ok, run} <- start_metrics_run(platform, url, actor, token),
         {:ok, finished} <- poll_until_done(run, token, poll_max_attempts()),
         {:ok, items} <- fetch_items(finished["defaultDatasetId"], token) do
      normalise_metrics(items)
    end
  end

  defp start_metrics_run(platform, url, actor, token) do
    body = build_metrics_input(platform, url)

    actor
    |> build_req("/v2/acts/#{actor}/runs", token)
    |> Req.post(json: body)
    |> classify()
    |> extract_data()
  end

  # Per-platform input shapes per BUILDPLAN section 17.7. Twitter
  # and YouTube cap maxItems=1 because their actors are otherwise
  # paginating crawlers and we only want the one published post.
  # LinkedIn and Instagram use platform-specific keys (`urls`,
  # `directUrls`) per their actor schemas.
  defp build_metrics_input("twitter", url),
    do: %{"startUrls" => [url], "maxItems" => 1}

  defp build_metrics_input("youtube", url),
    do: %{"startUrls" => [url], "maxItems" => 1}

  defp build_metrics_input("linkedin", url), do: %{"urls" => [url]}
  defp build_metrics_input("instagram", url), do: %{"directUrls" => [url]}
  defp build_metrics_input(_platform, url), do: %{"startUrls" => [url]}

  defp normalise_metrics(items) when is_list(items) do
    items
    |> Enum.reject(&no_results_marker?/1)
    |> List.first()
    |> metrics_from_item()
  end

  defp normalise_metrics(_), do: {:error, :apify_parse_failure}

  defp metrics_from_item(nil), do: {:error, :apify_parse_failure}

  # Lenient field-priority lookup, extending the 17.1 post-list
  # normalizer with views. Keys cover the common shapes across the
  # six configured actors. `optional_integer/2` returns `nil` when
  # the field is absent or unparseable; callers must not assume
  # zero on missing.
  defp metrics_from_item(item) when is_map(item) do
    {:ok,
     %{
       "likes" =>
         optional_integer(item, [
           "likeCount",
           "likesCount",
           "numLikes",
           "likes",
           "score",
           "ups",
           "reactions"
         ]),
       "comments" =>
         optional_integer(item, [
           "replyCount",
           "repliesCount",
           "numComments",
           "commentsCount",
           "comments",
           "numberOfComments",
           "num_comments"
         ]),
       "shares" =>
         optional_integer(item, [
           "retweetCount",
           "retweetsCount",
           "numShares",
           "sharesCount",
           "shares",
           "repostCount",
           "reposts"
         ]),
       "views" =>
         optional_integer(item, [
           "viewCount",
           "viewsCount",
           "numViews",
           "views",
           "playCount",
           "videoViews"
         ])
     }}
  end

  defp metrics_actor_for(platform) do
    config(:metrics_actors, %{}) |> Map.get(platform) || actor_for(platform)
  end

  defp dispatch_comments(_post, _limit, nil, _actor), do: {:error, :not_configured}
  defp dispatch_comments(_post, _limit, "", _actor), do: {:error, :not_configured}
  defp dispatch_comments(_post, _limit, _token, nil), do: {:error, :unsupported_platform}

  defp dispatch_comments(%CompetitorPost{conversation_id: nil}, _limit, _token, _actor),
    do: {:error, :missing_conversation_id}

  defp dispatch_comments(%CompetitorPost{} = post, limit, token, actor) do
    with {:ok, run} <- start_comment_run(post, actor, token, limit),
         {:ok, finished} <- poll_until_done(run, token, poll_max_attempts()),
         {:ok, items} <- fetch_items(finished["defaultDatasetId"], token) do
      {:ok, normalise_comments(items, post, limit)}
    end
  end

  defp start_comment_run(%CompetitorPost{} = post, actor, token, limit) do
    body = build_comment_input(post, limit)

    actor
    |> build_req("/v2/acts/#{actor}/runs", token)
    |> Req.post(json: body)
    |> classify()
    |> extract_data()
  end

  defp build_comment_input(%CompetitorPost{conversation_id: conv_id, post_url: url}, limit) do
    # Same conservative-superset shape as build_run_input/1 - actors
    # ignore unknown keys, so passing a few common id keys plus the
    # original URL covers the actors that vary in their input schema.
    %{
      conversationId: conv_id,
      conversation_id: conv_id,
      tweetId: conv_id,
      tweet_id: conv_id,
      postUrl: url,
      url: url,
      onlyComments: true,
      maxItems: limit,
      mode: "replies"
    }
  end

  defp normalise_comments(items, %CompetitorPost{} = post, limit) when is_list(items) do
    items
    |> Enum.reject(&no_results_marker?/1)
    |> Enum.map(&normalise_comment(&1, post))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1[:likes_count], :desc)
    |> Enum.take(limit)
  end

  defp normalise_comments(_other, _post, _limit), do: []

  defp normalise_comment(item, %CompetitorPost{} = post) when is_map(item) do
    comment_id = first_present(item, ["id", "commentId", "tweetId", "replyId"])

    if is_binary(comment_id) and comment_id != "" do
      author = item["author"] || %{}

      %{
        competitor_post_id: post.id,
        platform_comment_id: comment_id,
        author_handle: first_present(author, ["userName", "screen_name", "handle"]),
        text: first_present(item, ["text", "fullText", "content"]) || "",
        posted_at:
          item
          |> first_present(["createdAt", "postedAt", "publishedAt", "timestamp"])
          |> parse_datetime(),
        likes_count: integer_field(item, ["likeCount", "likesCount", "likes"]),
        replies_count: integer_field(item, ["replyCount", "repliesCount", "replies"]),
        retweets_count: integer_field(item, ["retweetCount", "retweetsCount", "retweets"]),
        views_count: integer_field(item, ["viewCount", "viewsCount", "views"]),
        in_reply_to_id: first_present(item, ["inReplyToId", "in_reply_to_id"]),
        conversation_id:
          first_present(item, ["conversationId", "conversation_id"]) || post.conversation_id,
        raw_payload: item
      }
    end
  end

  defp normalise_comment(_item, _post), do: nil

  defp comment_actor_for(nil), do: nil

  defp comment_actor_for(platform) when is_binary(platform) do
    Map.get(comment_actor_map(), platform) || actor_for(platform)
  end

  defp comment_actor_map do
    config(:comment_actors, %{})
  end

  defp infer_platform(%CompetitorPost{post_url: url}) when is_binary(url) do
    cond do
      url =~ ~r/x\.com|twitter\.com/ -> "twitter"
      url =~ ~r/linkedin\.com/ -> "linkedin"
      url =~ ~r/reddit\.com/ -> "reddit"
      url =~ ~r/facebook\.com/ -> "facebook"
      url =~ ~r/instagram\.com/ -> "instagram"
      url =~ ~r/youtube\.com|youtu\.be/ -> "youtube"
      true -> nil
    end
  end

  defp infer_platform(_), do: nil

  defp default_comment_limit do
    ContentForge.CompetitorResearch.max_comments_per_viral_post()
  end

  # --- dispatch -------------------------------------------------------------

  defp dispatch(_account, nil, _actor), do: {:error, :not_configured}
  defp dispatch(_account, "", _actor), do: {:error, :not_configured}
  defp dispatch(_account, _token, nil), do: {:error, :unsupported_platform}

  defp dispatch(account, token, actor) do
    with {:ok, run} <- start_run(account, token, actor),
         {:ok, finished} <- poll_until_done(run, token, poll_max_attempts()),
         {:ok, items} <- fetch_items(finished["defaultDatasetId"], token) do
      normalise_items(items, account.platform)
    end
  end

  # --- HTTP operations -----------------------------------------------------

  defp start_run(account, token, actor) do
    body = build_run_input(account)

    actor
    |> build_req("/v2/acts/#{actor}/runs", token)
    |> Req.post(json: body)
    |> classify()
    |> extract_data()
  end

  defp poll_until_done(_run, _token, 0), do: {:error, :apify_run_poll_timeout}

  defp poll_until_done(run, token, attempts_left) do
    run_id = run["id"]

    case run
         |> Map.get("id")
         |> fetch_run(token) do
      {:ok, %{"status" => status} = updated} when status in @terminal_success ->
        {:ok, updated}

      {:ok, %{"status" => status}} when status in @terminal_failure ->
        Logger.error("ApifyAdapter: run #{run_id} ended with status #{status}")
        {:error, {:apify_run_failed, status}}

      {:ok, _pending} ->
        Process.sleep(poll_interval_ms())
        poll_until_done(run, token, attempts_left - 1)

      {:error, _} = err ->
        err
    end
  end

  defp fetch_run(run_id, token) do
    run_id
    |> build_req("/v2/actor-runs/#{run_id}", token)
    |> Req.get()
    |> classify()
    |> extract_data()
  end

  defp fetch_items(dataset_id, token) when is_binary(dataset_id) do
    dataset_id
    |> build_req("/v2/datasets/#{dataset_id}/items", token)
    |> Req.get()
    |> classify_items()
  end

  defp fetch_items(_, _), do: {:error, :apify_missing_dataset_id}

  defp classify_items({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 and is_list(body),
       do: {:ok, body}

  defp classify_items({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299,
       do: {:error, {:unexpected_body, body}}

  defp classify_items({:ok, %Req.Response{status: status, body: body}}),
    do: classify({:ok, %Req.Response{status: status, body: body}})

  defp classify_items({:error, _} = err), do: classify(err)

  defp build_req(_key, path, token) do
    base = [
      url: path,
      base_url: base_url(),
      headers: [{"authorization", "Bearer #{token}"}],
      receive_timeout: 30_000,
      retry: false
    ]

    Req.new(base ++ extra_req_options())
  end

  defp build_run_input(%CompetitorAccount{handle: handle, url: url, platform: platform}) do
    # Apify actors accept different input shapes per actor. We pass a
    # conservative superset: handle under several common keys, plus
    # the `from` key kaitoeasyapi requires for handle-driven Twitter
    # scrapes (Phase 17.1). Other actors ignore keys they do not know.
    %{
      handle: handle,
      username: handle,
      screenName: handle,
      from: handle,
      searchTerms: [handle],
      startUrls: (url && [%{url: url}]) || [],
      maxItems: 25,
      platform: platform
    }
  end

  # --- response classification ---------------------------------------------

  defp classify({:ok, %Req.Response{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp classify({:ok, %Req.Response{status: status, body: body}}) when status in 300..399,
    do: {:error, {:unexpected_status, status, body}}

  defp classify({:ok, %Req.Response{status: 429, body: body}}),
    do: {:error, {:transient, 429, body}}

  defp classify({:ok, %Req.Response{status: status, body: body}}) when status in 400..499,
    do: {:error, {:http_error, status, body}}

  defp classify({:ok, %Req.Response{status: status, body: body}}) when status >= 500,
    do: {:error, {:transient, status, body}}

  defp classify({:error, %Req.TransportError{reason: :timeout} = err}),
    do: {:error, {:transient, :timeout, err.reason}}

  defp classify({:error, %Req.TransportError{reason: reason}})
       when reason in [:econnrefused, :nxdomain, :ehostunreach, :enetunreach, :closed],
       do: {:error, {:transient, :network, reason}}

  defp classify({:error, reason}), do: {:error, reason}

  defp extract_data({:ok, %{"data" => data}}) when is_map(data), do: {:ok, data}
  defp extract_data({:ok, body}), do: {:error, {:unexpected_body, body}}
  defp extract_data({:error, _} = err), do: err

  # --- normalisation -------------------------------------------------------

  defp normalise_items(items, platform) when is_list(items) do
    # Defensive filter: kaitoeasyapi (and any actor that adopts the
    # same convention) returns a `noResults: true` placeholder when
    # the requested handle has no posts. Drop those before counting,
    # otherwise an empty handle would look like a parse failure.
    filtered = Enum.reject(items, &no_results_marker?/1)

    {posts, skipped} =
      Enum.reduce(filtered, {[], 0}, fn item, {acc, skipped} ->
        case normalise_item(item, platform) do
          {:ok, post} -> {[post | acc], skipped}
          :skip -> {acc, skipped + 1}
        end
      end)

    if skipped > 0 do
      Logger.warning(
        "ApifyAdapter: skipped #{skipped} unparseable items for platform #{platform}"
      )
    end

    classify_normalised(posts, filtered, items, platform)
  end

  defp normalise_items(_other, _platform), do: {:error, :apify_parse_failure}

  # When every raw item carried a `noResults` marker we return an
  # empty list rather than `:apify_parse_failure` - the actor told
  # us cleanly there is nothing to ingest.
  defp classify_normalised([], [], _raw, _platform), do: {:ok, []}

  defp classify_normalised([], _filtered, raw_items, platform) do
    Logger.error(
      "ApifyAdapter: parse failure - zero items normalised from #{length(raw_items)} raw items for platform #{platform}"
    )

    {:error, :apify_parse_failure}
  end

  defp classify_normalised(posts, _filtered, _raw, _platform), do: {:ok, Enum.reverse(posts)}

  defp no_results_marker?(%{"noResults" => true}), do: true
  defp no_results_marker?(%{noResults: true}), do: true
  defp no_results_marker?(_), do: false

  defp normalise_item(item, _platform) when is_map(item) do
    post_id = first_present(item, ["id", "postId", "urn", "url", "videoId"])
    content = first_present(item, ["text", "caption", "title", "description", "content"]) || ""
    post_url = first_present(item, ["url", "postUrl", "post_url", "link"]) || ""
    likes = integer_field(item, ["likeCount", "likesCount", "numLikes", "likes", "score"])

    comments =
      integer_field(item, [
        "replyCount",
        "numComments",
        "commentsCount",
        "comments",
        "numberOfComments"
      ])

    shares = integer_field(item, ["retweetCount", "numShares", "sharesCount", "shares"])
    views = integer_field(item, ["viewCount", "viewsCount", "views"])
    conversation_id = first_present(item, ["conversationId", "conversation_id"])

    posted_at =
      item
      |> first_present(["createdAt", "postedAt", "publishedAt", "timestamp", "date"])
      |> parse_datetime()

    if is_binary(post_id) and post_id != "" and match?(%DateTime{}, posted_at) do
      {:ok,
       %{
         post_id: post_id,
         content: content,
         post_url: post_url,
         likes_count: likes,
         comments_count: comments,
         shares_count: shares,
         views_count: views,
         conversation_id: conversation_id,
         posted_at: posted_at,
         raw_data: item
       }}
    else
      :skip
    end
  end

  defp normalise_item(_item, _platform), do: :skip

  defp first_present(_item, []), do: nil

  defp first_present(item, [key | rest]) do
    case item[key] do
      nil -> first_present(item, rest)
      "" -> first_present(item, rest)
      value -> value
    end
  end

  defp integer_field(item, keys), do: integer_field_value(first_present(item, keys))

  # Variant for Phase 17.7 metrics: missing fields return nil (not 0)
  # so MetricsPoller can distinguish "not measured" from "measured as zero".
  defp optional_integer(item, keys), do: optional_integer_value(first_present(item, keys))

  defp optional_integer_value(n) when is_integer(n), do: n
  defp optional_integer_value(n) when is_float(n), do: trunc(n)

  defp optional_integer_value(n) when is_binary(n) do
    case Integer.parse(n) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp optional_integer_value(_), do: nil

  defp integer_field_value(n) when is_integer(n), do: n
  defp integer_field_value(n) when is_float(n), do: trunc(n)

  defp integer_field_value(n) when is_binary(n) do
    case Integer.parse(n) do
      {int, _} -> int
      :error -> 0
    end
  end

  defp integer_field_value(_), do: 0

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(%DateTime{} = dt), do: dt
  defp parse_datetime(_), do: nil

  # --- config --------------------------------------------------------------

  defp status_from_token(nil), do: :not_configured
  defp status_from_token(""), do: :not_configured
  defp status_from_token(_token), do: :ok

  defp actor_for(platform) do
    config(:actors, %{}) |> Map.get(platform)
  end

  defp base_url, do: config(:base_url) || @default_base_url
  defp fetch_token, do: config(:token)
  defp poll_interval_ms, do: config(:poll_interval_ms) || @default_poll_interval_ms
  defp poll_max_attempts, do: config(:poll_max_attempts) || @default_poll_max_attempts
  defp extra_req_options, do: config(:req_options) || []

  defp config(key, default \\ nil) do
    @config_app
    |> Application.get_env(@config_key, [])
    |> Keyword.get(key, default)
  end
end
