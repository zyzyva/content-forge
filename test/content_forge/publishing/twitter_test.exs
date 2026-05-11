defmodule ContentForge.Publishing.TwitterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ContentForge.Publishing.Twitter

  @twitter_config_key :twitter
  @apify_config_key :apify
  @twitter_stub ContentForge.Publishing.Twitter
  @apify_stub ContentForge.CompetitorScraper.ApifyAdapter

  setup do
    twitter_original = Application.get_env(:content_forge, @twitter_config_key, [])
    apify_original = Application.get_env(:content_forge, @apify_config_key, [])

    on_exit(fn ->
      Application.put_env(:content_forge, @twitter_config_key, twitter_original)
      Application.put_env(:content_forge, @apify_config_key, apify_original)
    end)

    Application.put_env(:content_forge, @twitter_config_key,
      base_url: "http://twitter.test",
      req_options: [plug: {Req.Test, @twitter_stub}, retry: false]
    )

    Application.put_env(:content_forge, @apify_config_key,
      base_url: "http://apify.test",
      token: "apify-test-token",
      actors: %{
        "twitter" => "kaitoeasyapi~twitter-x-data-tweet-scraper-pay-per-result-cheapest"
      },
      poll_interval_ms: 0,
      poll_max_attempts: 5,
      req_options: [plug: {Req.Test, @apify_stub}]
    )

    :ok
  end

  describe "fetch_metrics/3 with twitter_access_token (OAuth path preserved)" do
    test "returns engagement counts from native v2 /tweets/:id endpoint" do
      Req.Test.stub(@twitter_stub, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/tweets/1234567890"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer oauth-token"]

        Req.Test.json(conn, %{
          "data" => %{
            "id" => "1234567890",
            "public_metrics" => %{
              "like_count" => 42,
              "retweet_count" => 7,
              "reply_count" => 3,
              "quote_count" => 2
            }
          }
        })
      end)

      assert {:ok, metrics} =
               Twitter.fetch_metrics(
                 "1234567890",
                 "https://x.com/i/status/1234567890",
                 %{twitter_access_token: "oauth-token", twitter_api_key: "api-key"}
               )

      assert metrics["likes"] == 42
      assert metrics["retweets"] == 7
      assert metrics["replies"] == 3
      assert metrics["quotes"] == 2
    end

    test "non-2xx response surfaces an {:error, _} tuple, not zero-filled metrics" do
      Req.Test.stub(@twitter_stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(401, JSON.encode!(%{"error" => "unauthorized"}))
      end)

      capture_log(fn ->
        assert {:error, _reason} =
                 Twitter.fetch_metrics(
                   "1234567890",
                   "https://x.com/i/status/1234567890",
                   %{twitter_access_token: "oauth-token", twitter_api_key: "api-key"}
                 )
      end)
    end
  end

  describe "fetch_metrics/3 without twitter_access_token (Phase 17.7 Apify dispatch)" do
    test "delegates to ApifyAdapter.fetch_metrics_for_post/2 with the given post_url" do
      Req.Test.stub(@twitter_stub, fn _conn ->
        flunk("OAuth path must not be hit when twitter_access_token is absent")
      end)

      Req.Test.stub(@apify_stub, fn conn ->
        cond do
          conn.method == "POST" and String.starts_with?(conn.request_path, "/v2/acts/") ->
            Req.Test.json(conn, %{
              "data" => %{"id" => "r1", "status" => "READY", "defaultDatasetId" => "d1"}
            })

          conn.request_path == "/v2/actor-runs/r1" ->
            Req.Test.json(conn, %{
              "data" => %{"id" => "r1", "status" => "SUCCEEDED", "defaultDatasetId" => "d1"}
            })

          conn.request_path == "/v2/datasets/d1/items" ->
            Req.Test.json(conn, [
              %{
                "id" => "1900003",
                "url" => "https://x.com/i/status/1900003",
                "createdAt" => "2026-04-22T12:00:00.000Z",
                "likeCount" => 11,
                "replyCount" => 5,
                "retweetCount" => 9,
                "quoteCount" => 1,
                "viewCount" => 999
              }
            ])
        end
      end)

      assert {:ok, metrics} =
               Twitter.fetch_metrics("1900003", "https://x.com/i/status/1900003", %{})

      assert metrics["likes"] == 11
      assert metrics["comments"] == 5
      assert metrics["shares"] == 9
      assert metrics["views"] == 999
    end

    test "nil post_url is reconstructed from the tweet id (Twitter is URL-reconstructible)" do
      ref = make_ref()
      test_pid = self()

      Req.Test.stub(@apify_stub, fn conn ->
        cond do
          conn.method == "POST" and String.starts_with?(conn.request_path, "/v2/acts/") ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {ref, :input, body})

            Req.Test.json(conn, %{
              "data" => %{"id" => "r2", "status" => "READY", "defaultDatasetId" => "d2"}
            })

          conn.request_path == "/v2/actor-runs/r2" ->
            Req.Test.json(conn, %{
              "data" => %{"id" => "r2", "status" => "SUCCEEDED", "defaultDatasetId" => "d2"}
            })

          conn.request_path == "/v2/datasets/d2/items" ->
            Req.Test.json(conn, [
              %{
                "id" => "555",
                "url" => "https://x.com/i/status/555",
                "createdAt" => "2026-04-22T12:00:00.000Z",
                "likeCount" => 1
              }
            ])
        end
      end)

      assert {:ok, _} = Twitter.fetch_metrics("555", nil, %{})

      assert_receive {^ref, :input, raw_body}
      decoded = Jason.decode!(raw_body)
      assert decoded["startUrls"] == ["https://x.com/i/status/555"]
    end

    test "missing APIFY_TOKEN propagates {:error, :not_configured}" do
      Application.put_env(:content_forge, @apify_config_key,
        base_url: "http://apify.test",
        token: nil,
        actors: %{
          "twitter" => "kaitoeasyapi~twitter-x-data-tweet-scraper-pay-per-result-cheapest"
        },
        poll_interval_ms: 0,
        poll_max_attempts: 5,
        req_options: [plug: {Req.Test, @apify_stub}]
      )

      Req.Test.stub(@apify_stub, fn _conn ->
        flunk("no HTTP expected when APIFY_TOKEN is missing")
      end)

      assert {:error, :not_configured} =
               Twitter.fetch_metrics("1900003", "https://x.com/i/status/1900003", %{})
    end

    test "Apify HTTP error surfaces classified error, not zero-filled metrics" do
      Req.Test.stub(@apify_stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, JSON.encode!(%{"error" => "boom"}))
      end)

      assert {:error, {:transient, 500, _}} =
               Twitter.fetch_metrics("1900003", "https://x.com/i/status/1900003", %{})
    end
  end
end
