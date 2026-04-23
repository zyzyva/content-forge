defmodule ContentForge.CompetitorScraper.ApifyAdapterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ContentForge.CompetitorScraper.ApifyAdapter
  alias ContentForge.Products.CompetitorAccount

  @config_key :apify
  @stub_key ContentForge.CompetitorScraper.ApifyAdapter

  setup do
    original = Application.get_env(:content_forge, @config_key, [])

    on_exit(fn ->
      Application.put_env(:content_forge, @config_key, original)
    end)

    Application.put_env(:content_forge, @config_key,
      base_url: "http://apify.test",
      token: "apify-test-token",
      actors: %{
        "twitter" => "apify~twitter-scraper",
        "linkedin" => "apify~linkedin-post-scraper",
        "reddit" => "trudax~reddit-scraper",
        "facebook" => "apify~facebook-pages-scraper",
        "instagram" => "apify~instagram-scraper",
        "youtube" => "apify~youtube-scraper"
      },
      poll_interval_ms: 0,
      poll_max_attempts: 5,
      req_options: [plug: {Req.Test, @stub_key}]
    )

    :ok
  end

  defp cfg, do: Application.get_env(:content_forge, @config_key)

  defp put_cfg(cfg), do: Application.put_env(:content_forge, @config_key, cfg)

  defp account(attrs \\ %{}) do
    defaults = %{platform: "twitter", handle: "acme", url: nil}
    data = Map.merge(defaults, attrs)

    %CompetitorAccount{
      platform: data.platform,
      handle: data.handle,
      url: data.url
    }
  end

  # Stages a stub that runs a two-call Apify flow: POST /v2/acts/<actor>/runs
  # returns a run id, GET /v2/actor-runs/<run_id> returns SUCCEEDED with a
  # dataset id, GET /v2/datasets/<dataset_id>/items returns `items`.
  defp stage_success(items, actor, run_id \\ "run_1", dataset_id \\ "ds_1") do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(@stub_key, fn conn ->
      Agent.update(counter, &(&1 + 1))
      call = Agent.get(counter, & &1)

      cond do
        conn.request_path == "/v2/acts/#{actor}/runs" and conn.method == "POST" ->
          Req.Test.json(conn, %{
            "data" => %{
              "id" => run_id,
              "status" => "READY",
              "defaultDatasetId" => dataset_id
            }
          })

        conn.request_path == "/v2/actor-runs/#{run_id}" ->
          status = if call <= 2, do: "RUNNING", else: "SUCCEEDED"

          Req.Test.json(conn, %{
            "data" => %{
              "id" => run_id,
              "status" => status,
              "defaultDatasetId" => dataset_id
            }
          })

        conn.request_path == "/v2/datasets/#{dataset_id}/items" ->
          Req.Test.json(conn, items)

        true ->
          flunk("unexpected call to #{conn.method} #{conn.request_path}")
      end
    end)

    :ok
  end

  describe "status/0" do
    test "returns :ok when token is configured" do
      assert ApifyAdapter.status() == :ok
    end

    test "returns :not_configured when token is missing" do
      put_cfg(Keyword.delete(cfg(), :token))
      assert ApifyAdapter.status() == :not_configured
    end

    test "returns :not_configured when token is empty" do
      put_cfg(Keyword.put(cfg(), :token, ""))
      assert ApifyAdapter.status() == :not_configured
    end
  end

  describe "missing token" do
    test "returns {:error, :not_configured} with zero HTTP" do
      put_cfg(Keyword.put(cfg(), :token, nil))

      test_pid = self()

      Req.Test.stub(@stub_key, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no HTTP expected when apify token is missing"
      end)

      assert {:error, :not_configured} = ApifyAdapter.fetch_posts(account())
      refute_received :unexpected_http
    end
  end

  describe "unsupported platform" do
    test "returns {:error, :unsupported_platform} with zero HTTP" do
      put_cfg(
        Keyword.put(cfg(), :actors, %{
          "twitter" => "apify~twitter-scraper"
          # no mapping for blog
        })
      )

      test_pid = self()

      Req.Test.stub(@stub_key, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no HTTP expected for unsupported platform"
      end)

      assert {:error, :unsupported_platform} =
               ApifyAdapter.fetch_posts(account(%{platform: "blog"}))

      refute_received :unexpected_http
    end
  end

  describe "happy-path scrape per platform" do
    test "twitter: normalises actor output to the expected post map shape" do
      items = [
        %{
          "id" => "1999999",
          "text" => "Hello Twitter",
          "url" => "https://twitter.com/acme/status/1999999",
          "likeCount" => 42,
          "replyCount" => 3,
          "retweetCount" => 7,
          "createdAt" => "2026-04-20T12:34:56.000Z"
        }
      ]

      stage_success(items, "apify~twitter-scraper")

      assert {:ok, [post]} = ApifyAdapter.fetch_posts(account(%{platform: "twitter"}))
      assert post.post_id == "1999999"
      assert post.content == "Hello Twitter"
      assert post.post_url == "https://twitter.com/acme/status/1999999"
      assert post.likes_count == 42
      assert post.comments_count == 3
      assert post.shares_count == 7
      assert %DateTime{} = post.posted_at
    end

    test "linkedin: normalises the numLikes/numComments/numShares shape" do
      items = [
        %{
          "urn" => "urn:li:activity:123",
          "text" => "LinkedIn post",
          "url" => "https://linkedin.com/posts/123",
          "numLikes" => 55,
          "numComments" => 4,
          "numShares" => 2,
          "postedAt" => "2026-04-20T12:00:00Z"
        }
      ]

      stage_success(items, "apify~linkedin-post-scraper")

      assert {:ok, [post]} = ApifyAdapter.fetch_posts(account(%{platform: "linkedin"}))
      assert post.post_id == "urn:li:activity:123"
      assert post.likes_count == 55
      assert post.comments_count == 4
      assert post.shares_count == 2
    end

    test "reddit: normalises score/comments shape" do
      items = [
        %{
          "id" => "reddit_abc",
          "title" => "Reddit title",
          "url" => "https://reddit.com/r/foo/comments/abc",
          "score" => 123,
          "numberOfComments" => 17,
          "createdAt" => "2026-04-20T10:00:00Z"
        }
      ]

      stage_success(items, "trudax~reddit-scraper")

      assert {:ok, [post]} = ApifyAdapter.fetch_posts(account(%{platform: "reddit"}))
      assert post.likes_count == 123
      assert post.comments_count == 17
    end

    test "facebook: normalises likes/comments/shares shape" do
      items = [
        %{
          "postId" => "fb_9001",
          "text" => "Facebook post",
          "url" => "https://facebook.com/posts/9001",
          "likes" => 80,
          "comments" => 12,
          "shares" => 4,
          "timestamp" => "2026-04-20T08:00:00Z"
        }
      ]

      stage_success(items, "apify~facebook-pages-scraper")

      assert {:ok, [post]} = ApifyAdapter.fetch_posts(account(%{platform: "facebook"}))
      assert post.likes_count == 80
      assert post.comments_count == 12
      assert post.shares_count == 4
    end

    test "instagram: normalises image/reel shape" do
      items = [
        %{
          "id" => "ig_7777",
          "caption" => "Insta caption",
          "url" => "https://instagram.com/p/7777",
          "likesCount" => 250,
          "commentsCount" => 30,
          "timestamp" => "2026-04-20T07:00:00Z"
        }
      ]

      stage_success(items, "apify~instagram-scraper")

      assert {:ok, [post]} = ApifyAdapter.fetch_posts(account(%{platform: "instagram"}))
      assert post.likes_count == 250
      assert post.comments_count == 30
    end

    test "youtube: normalises video shape" do
      items = [
        %{
          "id" => "yt_AbCd",
          "title" => "YT title",
          "url" => "https://youtube.com/watch?v=AbCd",
          "viewCount" => 5000,
          "likes" => 300,
          "comments" => 45,
          "publishedAt" => "2026-04-20T06:00:00Z"
        }
      ]

      stage_success(items, "apify~youtube-scraper")

      assert {:ok, [post]} = ApifyAdapter.fetch_posts(account(%{platform: "youtube"}))
      assert post.likes_count == 300
      assert post.comments_count == 45
    end
  end

  describe "authentication" do
    test "attaches Authorization: Bearer <token> on every request" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(@stub_key, fn conn ->
        Agent.update(counter, &(&1 + 1))
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer apify-test-token"]

        cond do
          conn.request_path == "/v2/acts/apify~twitter-scraper/runs" ->
            Req.Test.json(conn, %{
              "data" => %{"id" => "r1", "status" => "READY", "defaultDatasetId" => "d1"}
            })

          conn.request_path == "/v2/actor-runs/r1" ->
            Req.Test.json(conn, %{
              "data" => %{"id" => "r1", "status" => "SUCCEEDED", "defaultDatasetId" => "d1"}
            })

          conn.request_path == "/v2/datasets/d1/items" ->
            Req.Test.json(conn, [
              %{"id" => "x", "text" => "t", "url" => "u", "createdAt" => "2026-04-20T00:00:00Z"}
            ])
        end
      end)

      assert {:ok, [_]} = ApifyAdapter.fetch_posts(account(%{platform: "twitter"}))
      assert Agent.get(counter, & &1) == 3
    end
  end

  describe "error classification" do
    test "429 on actor-run creation is transient" do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(429, JSON.encode!(%{"error" => "rate_limit"}))
      end)

      assert {:error, {:transient, 429, _}} =
               ApifyAdapter.fetch_posts(account(%{platform: "twitter"}))
    end

    test "500 on actor-run creation is transient" do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, JSON.encode!(%{"error" => "internal"}))
      end)

      assert {:error, {:transient, 500, _}} =
               ApifyAdapter.fetch_posts(account(%{platform: "twitter"}))
    end

    test "400 on actor-run creation is permanent" do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, JSON.encode!(%{"error" => "invalid"}))
      end)

      assert {:error, {:http_error, 400, _}} =
               ApifyAdapter.fetch_posts(account(%{platform: "twitter"}))
    end

    test "transport timeout classifies as transient :timeout" do
      Req.Test.stub(@stub_key, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, {:transient, :timeout, _}} =
               ApifyAdapter.fetch_posts(account(%{platform: "twitter"}))
    end

    test "unexpected 304 reaches the classifier" do
      Req.Test.stub(@stub_key, fn conn ->
        Plug.Conn.resp(conn, 304, "")
      end)

      assert {:error, {:unexpected_status, 304, _}} =
               ApifyAdapter.fetch_posts(account(%{platform: "twitter"}))
    end

    test "actor-run status FAILED returns permanent error" do
      Req.Test.stub(@stub_key, fn conn ->
        cond do
          conn.request_path == "/v2/acts/apify~twitter-scraper/runs" ->
            Req.Test.json(conn, %{
              "data" => %{"id" => "r_fail", "status" => "READY", "defaultDatasetId" => "d1"}
            })

          conn.request_path == "/v2/actor-runs/r_fail" ->
            Req.Test.json(conn, %{
              "data" => %{
                "id" => "r_fail",
                "status" => "FAILED",
                "defaultDatasetId" => "d1"
              }
            })
        end
      end)

      log =
        capture_log(fn ->
          assert {:error, {:apify_run_failed, "FAILED"}} =
                   ApifyAdapter.fetch_posts(account(%{platform: "twitter"}))
        end)

      assert log =~ "FAILED"
    end

    test "poll timeout when run never leaves RUNNING returns an error" do
      Req.Test.stub(@stub_key, fn conn ->
        cond do
          conn.request_path == "/v2/acts/apify~twitter-scraper/runs" ->
            Req.Test.json(conn, %{
              "data" => %{"id" => "r_slow", "status" => "READY", "defaultDatasetId" => "d1"}
            })

          conn.request_path == "/v2/actor-runs/r_slow" ->
            Req.Test.json(conn, %{
              "data" => %{
                "id" => "r_slow",
                "status" => "RUNNING",
                "defaultDatasetId" => "d1"
              }
            })
        end
      end)

      assert {:error, :apify_run_poll_timeout} =
               ApifyAdapter.fetch_posts(account(%{platform: "twitter"}))
    end
  end

  describe "parse behaviour" do
    test "partial parse: items missing required fields are skipped; surviving items returned" do
      items = [
        %{
          "id" => "good_1",
          "text" => "valid",
          "url" => "https://x.com/1",
          "likeCount" => 1,
          "replyCount" => 0,
          "retweetCount" => 0,
          "createdAt" => "2026-04-20T12:00:00Z"
        },
        # item missing a parseable timestamp AND missing identifiers -> skipped
        %{"likeCount" => 10},
        %{
          "id" => "good_2",
          "text" => "also valid",
          "url" => "https://x.com/2",
          "likeCount" => 2,
          "replyCount" => 0,
          "retweetCount" => 0,
          "createdAt" => "2026-04-20T12:01:00Z"
        }
      ]

      stage_success(items, "apify~twitter-scraper")

      log =
        capture_log(fn ->
          assert {:ok, posts} = ApifyAdapter.fetch_posts(account(%{platform: "twitter"}))
          send(self(), {:posts, posts})
        end)

      assert_received {:posts, posts}
      assert length(posts) == 2
      assert Enum.map(posts, & &1.post_id) == ["good_1", "good_2"]
      assert log =~ "skipped" or log =~ "parse"
    end

    test "complete parse failure returns a classified error" do
      items = [
        # every item missing required fields
        %{"likeCount" => 10},
        %{"commentsCount" => 1}
      ]

      stage_success(items, "apify~twitter-scraper")

      log =
        capture_log(fn ->
          assert {:error, :apify_parse_failure} =
                   ApifyAdapter.fetch_posts(account(%{platform: "twitter"}))
        end)

      assert log =~ "parse" or log =~ "skipped"
    end
  end
end
