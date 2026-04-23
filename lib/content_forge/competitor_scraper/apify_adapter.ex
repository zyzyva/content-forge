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
        posted_at: DateTime.t()
      }

  ## Actor ids chosen at 11.3a slice time

  These can be overridden in application config at any time. The
  defaults selected for the slice are widely-used Apify community
  scrapers; swap to paid or higher-fidelity actors by updating the
  `:actors` config map.

      %{
        "twitter"   => "apify~twitter-scraper",
        "linkedin"  => "apify~linkedin-post-scraper",
        "reddit"    => "trudax~reddit-scraper",
        "facebook"  => "apify~facebook-pages-scraper",
        "instagram" => "apify~instagram-scraper",
        "youtube"   => "apify~youtube-scraper"
      }

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
    # conservative superset: handle under a few common keys, and the
    # url if present. Actors ignore keys they do not know.
    %{
      handle: handle,
      username: handle,
      screenName: handle,
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
    {posts, skipped} =
      Enum.reduce(items, {[], 0}, fn item, {acc, skipped} ->
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

    case posts do
      [] ->
        Logger.error(
          "ApifyAdapter: parse failure - zero items normalised from #{length(items)} raw items for platform #{platform}"
        )

        {:error, :apify_parse_failure}

      _ ->
        {:ok, Enum.reverse(posts)}
    end
  end

  defp normalise_items(_other, _platform), do: {:error, :apify_parse_failure}

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
         posted_at: posted_at
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
