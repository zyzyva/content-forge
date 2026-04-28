defmodule ContentForge.Publishing.Reddit do
  @moduledoc """
  Reddit connector using Reddit API.
  Submits text posts to a configured subreddit.
  """

  require Logger

  alias ContentForge.CompetitorScraper.ApifyAdapter

  @base_url "https://oauth.reddit.com"
  @max_retries 3
  @retry_delay 5000

  @type post_result :: {:ok, %{post_id: String.t(), post_url: String.t()}} | {:error, String.t()}

  @doc """
  Submit a text post to a subreddit.

  ## Options
    - `:subreddit` - The subreddit to post to (required)
    - `:retry` - Number of retries (default: 3)
  """
  @spec post(binary(), map(), keyword()) :: post_result()
  def post(text, %{reddit_access_token: _token} = credentials, opts \\ []) do
    retry_count = Keyword.get(opts, :retry, @max_retries)
    subreddit = Keyword.fetch!(opts, :subreddit)
    do_post(text, credentials, subreddit, retry_count)
  end

  defp do_post(_text, _credentials, _subreddit, 0) do
    Logger.error("Reddit: All retries exhausted")
    {:error, "Failed to post after multiple attempts"}
  end

  defp do_post(text, credentials, subreddit, attempts_left) do
    case perform_post(text, credentials, subreddit) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        Logger.warning(
          "Reddit: Post failed, attempts left: #{attempts_left}, error: #{inspect(reason)}"
        )

        Process.sleep(@retry_delay)
        do_post(text, credentials, subreddit, attempts_left - 1)
    end
  end

  defp perform_post(text, credentials, subreddit) do
    path = "/r/#{subreddit}/submit"

    body = %{
      "kind" => "self",
      "sr" => subreddit,
      "text" => text,
      "api_type" => "json"
    }

    case reddit_request(:post, path, credentials, body) do
      {:ok, %{"json" => %{"data" => %{"id" => post_id, "url" => post_url}}}} ->
        Logger.info("Reddit: Posted to r/#{subreddit} #{post_id}")
        {:ok, %{post_id: post_id, post_url: post_url}}

      {:ok, %{"json" => %{"errors" => errors}}} when errors != [] ->
        Logger.error("Reddit: Submission errors: #{inspect(errors)}")
        {:error, errors}

      {:ok, response} ->
        Logger.error("Reddit: Unexpected response: #{inspect(response)}")
        {:error, "Unexpected response"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetch engagement metrics for a published Reddit post.

  Phase 17.7 dispatch: native Reddit OAuth path runs when the
  credentials map carries `:reddit_access_token`. When the token
  is absent (default for products that have not registered a
  Reddit app), routes through Apify so the system runs on
  `APIFY_TOKEN` alone. `post_url` is required for the Apify path.

  `post_id` is the Reddit post id (without the `t3_` prefix).
  """
  @spec fetch_metrics(String.t(), String.t() | nil, map()) :: {:ok, map()} | {:error, term()}
  def fetch_metrics(post_id, _post_url, %{reddit_access_token: _} = credentials) do
    fetch_metrics_via_oauth(post_id, credentials)
  end

  def fetch_metrics(_post_id, nil, _credentials_without_oauth), do: {:error, :no_post_url}

  def fetch_metrics(_post_id, post_url, _credentials_without_oauth) do
    ApifyAdapter.fetch_metrics_for_post("reddit", post_url)
  end

  defp fetch_metrics_via_oauth(post_id, credentials) do
    case reddit_request(:get, "/api/info.json?id=t3_#{post_id}", credentials) do
      {:ok, body} ->
        post_data = get_in(body, ["data", "children", Access.at(0), "data"]) || %{}

        {:ok,
         %{
           "upvotes" => post_data["ups"] || 0,
           "downvotes" => post_data["downs"] || 0,
           "comments" => post_data["num_comments"] || 0,
           "score" => post_data["score"] || 0
         }}

      {:error, _} = err ->
        err
    end
  end

  defp reddit_request(:get, path, credentials) do
    headers = [
      {"Authorization", "Bearer #{credentials.reddit_access_token}"},
      {"User-Agent", "ContentForge/1.0"}
    ]

    [url: path, base_url: base_url(), headers: headers]
    |> Kernel.++(req_options())
    |> Req.new()
    |> Req.get()
    |> case do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Reddit API error: #{status} - #{inspect(body)}")
        {:error, body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp base_url do
    Application.get_env(:content_forge, :reddit, []) |> Keyword.get(:base_url, @base_url)
  end

  defp req_options do
    Application.get_env(:content_forge, :reddit, []) |> Keyword.get(:req_options, [])
  end

  defp reddit_request(method, path, credentials, body) do
    url = @base_url <> path

    headers = [
      {"Authorization", "Bearer #{credentials.reddit_access_token}"},
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"User-Agent", "ContentForge/1.0"}
    ]

    # Convert body to form-encoded string
    encoded_body = URI.encode_query(body)

    case method do
      :post ->
        case Req.post(url, body: encoded_body, headers: headers) do
          {:ok, %{status: status, body: body}} when status in 200..299 ->
            {:ok, body}

          {:ok, %{status: status, body: body}} when status >= 400 ->
            Logger.error("Reddit API error: #{status} - #{inspect(body)}")
            {:error, body}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end
end
