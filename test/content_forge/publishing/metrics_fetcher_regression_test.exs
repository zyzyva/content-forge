defmodule ContentForge.Publishing.MetricsFetcherRegressionTest do
  @moduledoc """
  Phase 17.7 regression sweep.

  Pins the spec guarantee that every per-platform `fetch_metrics/2`
  surfaces a classified `{:error, _}` tuple on HTTP error, never
  an `{:ok, zero_filled_map}` shaped success. Zero-filled fallbacks
  are silent failures that poison the corrective-loop signal in
  `MetricsPoller` (a real "measured zero" cannot be distinguished
  from a 401 / 500 if the fetcher pretends the call succeeded).

  One test per native-API fetcher: Twitter (OAuth path), LinkedIn,
  Facebook, Reddit, YouTube. The Twitter Apify dispatch path is
  covered by `ContentForge.Publishing.TwitterTest` and
  `ContentForge.CompetitorScraper.ApifyAdapterTest`.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ContentForge.Publishing.{Facebook, LinkedIn, Reddit, Twitter, YouTube}

  @twitter_stub ContentForge.Publishing.Twitter
  @linkedin_stub ContentForge.Publishing.LinkedIn
  @facebook_stub ContentForge.Publishing.Facebook
  @reddit_stub ContentForge.Publishing.Reddit
  @youtube_stub ContentForge.Publishing.YouTube

  setup do
    originals = %{
      twitter: Application.get_env(:content_forge, :twitter, []),
      linkedin: Application.get_env(:content_forge, :linkedin, []),
      facebook: Application.get_env(:content_forge, :facebook, []),
      reddit: Application.get_env(:content_forge, :reddit, []),
      youtube: Application.get_env(:content_forge, :youtube, [])
    }

    on_exit(fn ->
      Enum.each(originals, fn {k, v} ->
        Application.put_env(:content_forge, k, v)
      end)
    end)

    Application.put_env(:content_forge, :twitter,
      base_url: "http://twitter.test",
      req_options: [plug: {Req.Test, @twitter_stub}, retry: false]
    )

    Application.put_env(:content_forge, :linkedin,
      base_url: "http://linkedin.test",
      req_options: [plug: {Req.Test, @linkedin_stub}, retry: false]
    )

    Application.put_env(:content_forge, :facebook,
      base_url: "http://facebook.test",
      req_options: [plug: {Req.Test, @facebook_stub}, retry: false]
    )

    Application.put_env(:content_forge, :reddit,
      base_url: "http://reddit.test",
      req_options: [plug: {Req.Test, @reddit_stub}, retry: false]
    )

    Application.put_env(:content_forge, :youtube,
      data_url: "http://yt.test/v3",
      analytics_url: "http://yt-analytics.test/v2",
      req_options: [plug: {Req.Test, @youtube_stub}, retry: false]
    )

    :ok
  end

  test "twitter fetch_metrics/3 returns {:error, _} on HTTP error, not zero-filled metrics" do
    Req.Test.stub(@twitter_stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(500, JSON.encode!(%{"error" => "boom"}))
    end)

    capture_log(fn ->
      result =
        Twitter.fetch_metrics("tweet-1", "https://x.com/i/status/tweet-1", %{
          twitter_access_token: "tok",
          twitter_api_key: "key"
        })

      assert match?({:error, _}, result)

      refute match?(
               {:ok, %{"likes" => 0, "retweets" => 0, "replies" => 0, "quotes" => 0}},
               result
             )
    end)
  end

  test "linkedin fetch_metrics/3 returns {:error, _} on HTTP error, not zero-filled metrics" do
    Req.Test.stub(@linkedin_stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(401, JSON.encode!(%{"message" => "unauthorized"}))
    end)

    capture_log(fn ->
      result =
        LinkedIn.fetch_metrics(
          "urn:li:ugcPost:abc",
          "https://linkedin.com/feed/update/urn:li:ugcPost:abc",
          %{linkedin_access_token: "tok"}
        )

      assert match?({:error, _}, result)

      refute match?(
               {:ok, %{"likes" => 0, "comments" => 0, "shares" => 0, "impressions" => 0}},
               result
             )
    end)
  end

  test "facebook fetch_metrics/3 returns {:error, _} on HTTP error, not zero-filled metrics" do
    Req.Test.stub(@facebook_stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(500, JSON.encode!(%{"error" => %{"message" => "server"}}))
    end)

    capture_log(fn ->
      result =
        Facebook.fetch_metrics(
          "post-1",
          "https://facebook.com/posts/1",
          %{facebook_access_token: "tok"}
        )

      assert match?({:error, _}, result)
      refute match?({:ok, %{"likes" => 0, "comments" => 0, "shares" => 0}}, result)
    end)
  end

  test "reddit fetch_metrics/3 returns {:error, _} on HTTP error, not zero-filled metrics" do
    Req.Test.stub(@reddit_stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(503, JSON.encode!(%{"error" => "unavailable"}))
    end)

    capture_log(fn ->
      result =
        Reddit.fetch_metrics(
          "abc123",
          "https://reddit.com/r/foo/comments/abc123",
          %{reddit_access_token: "tok"}
        )

      assert match?({:error, _}, result)

      refute match?(
               {:ok, %{"upvotes" => 0, "downvotes" => 0, "comments" => 0, "score" => 0}},
               result
             )
    end)
  end

  test "youtube fetch_metrics/3 returns {:error, _} on HTTP error, not zero-filled metrics" do
    Req.Test.stub(@youtube_stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(403, JSON.encode!(%{"error" => "forbidden"}))
    end)

    capture_log(fn ->
      result =
        YouTube.fetch_metrics(
          "vid-1",
          "https://www.youtube.com/watch?v=vid-1",
          %{youtube_access_token: "tok"}
        )

      assert match?({:error, _}, result)
      refute match?({:ok, %{"views" => 0, "likes" => 0, "comments" => 0}}, result)

      refute match?(
               {:ok, %{"views" => 0, "likes" => 0, "comments" => 0, "retention_curve" => _}},
               result
             )
    end)
  end
end
