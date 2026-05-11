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

  describe "Phase 17.1 kaitoeasyapi twitter response shape" do
    # Captured shape per RESEARCH_LOOP_PLAN.md Phase 1: kaitoeasyapi
    # responses include `viewCount` and `conversationId` we did not
    # surface previously, plus a `noResults` placeholder when the
    # actor finds nothing for the given handle.
    setup do
      put_cfg(
        Keyword.put(
          cfg(),
          :actors,
          Map.put(
            cfg()[:actors],
            "twitter",
            "kaitoeasyapi~twitter-x-data-tweet-scraper-pay-per-result-cheapest"
          )
        )
      )

      :ok
    end

    test "post normalisation surfaces views_count, conversation_id, and raw_data" do
      items = [
        %{
          "id" => "1888888",
          "text" => "viral take",
          "url" => "https://x.com/acme/status/1888888",
          "likeCount" => 4_200,
          "replyCount" => 311,
          "retweetCount" => 950,
          "viewCount" => 250_000,
          "conversationId" => "conv-1888888",
          "createdAt" => "2026-04-20T12:34:56.000Z",
          "author" => %{"userName" => "acme"}
        }
      ]

      stage_success(items, "kaitoeasyapi~twitter-x-data-tweet-scraper-pay-per-result-cheapest")

      assert {:ok, [post]} = ApifyAdapter.fetch_posts(account(%{platform: "twitter"}))
      assert post.post_id == "1888888"
      assert post.likes_count == 4_200
      assert post.comments_count == 311
      assert post.shares_count == 950
      assert post.views_count == 250_000
      assert post.conversation_id == "conv-1888888"
      assert post.raw_data["conversationId"] == "conv-1888888"
    end

    test "noResults marker items are dropped before normalisation" do
      items = [
        %{"noResults" => true, "id" => "noise-1"},
        %{
          "id" => "1999000",
          "text" => "real tweet",
          "url" => "https://x.com/acme/status/1999000",
          "likeCount" => 5,
          "replyCount" => 0,
          "retweetCount" => 0,
          "viewCount" => 100,
          "conversationId" => "conv-1999000",
          "createdAt" => "2026-04-20T13:00:00.000Z"
        }
      ]

      stage_success(items, "kaitoeasyapi~twitter-x-data-tweet-scraper-pay-per-result-cheapest")

      assert {:ok, [post]} = ApifyAdapter.fetch_posts(account(%{platform: "twitter"}))
      assert post.post_id == "1999000"
    end

    test "an all-noResults dataset returns an empty list cleanly (no parse_failure)" do
      items = [
        %{"noResults" => true, "id" => "noise-a"},
        %{"noResults" => true, "id" => "noise-b"}
      ]

      stage_success(items, "kaitoeasyapi~twitter-x-data-tweet-scraper-pay-per-result-cheapest")

      assert {:ok, []} = ApifyAdapter.fetch_posts(account(%{platform: "twitter"}))
    end

    test "fetch_comments/2 normalises kaitoeasyapi reply items, top-N by likes" do
      post = %ContentForge.Products.CompetitorPost{
        id: "00000000-0000-0000-0000-0000000000aa",
        post_url: "https://x.com/acme/status/1888888",
        conversation_id: "conv-1888888"
      }

      items = [
        %{
          "id" => "rep-1",
          "text" => "low resonance",
          "createdAt" => "2026-04-21T10:00:00.000Z",
          "likeCount" => 1,
          "author" => %{"userName" => "lurker"}
        },
        %{
          "id" => "rep-2",
          "text" => "high resonance",
          "createdAt" => "2026-04-21T11:00:00.000Z",
          "likeCount" => 75,
          "replyCount" => 4,
          "author" => %{"userName" => "fan42"}
        },
        %{"noResults" => true},
        %{
          "id" => "rep-3",
          "text" => "mid",
          "createdAt" => "2026-04-21T12:00:00.000Z",
          "likeCount" => 10
        }
      ]

      stage_success(items, "kaitoeasyapi~twitter-x-data-tweet-scraper-pay-per-result-cheapest")

      assert {:ok, comments} =
               ApifyAdapter.fetch_comments(post, limit: 2, platform: "twitter")

      assert length(comments) == 2
      assert [first, second] = comments
      assert first[:platform_comment_id] == "rep-2"
      assert first[:likes_count] == 75
      assert first[:author_handle] == "fan42"
      assert first[:competitor_post_id] == post.id
      assert first[:conversation_id] == "conv-1888888"
      assert first[:raw_payload]["author"]["userName"] == "fan42"
      assert second[:platform_comment_id] == "rep-3"
    end

    test "fetch_comments/2 returns :missing_conversation_id when post has none" do
      post = %ContentForge.Products.CompetitorPost{
        id: "00000000-0000-0000-0000-0000000000bb",
        conversation_id: nil,
        post_url: "https://x.com/acme/status/x"
      }

      assert {:error, :missing_conversation_id} =
               ApifyAdapter.fetch_comments(post, platform: "twitter")
    end

    test "the run input includes a `from` key alongside the existing handle keys" do
      ref = make_ref()
      test_pid = self()

      Req.Test.stub(@stub_key, fn conn ->
        cond do
          conn.method == "POST" and String.starts_with?(conn.request_path, "/v2/acts/") ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {ref, :run_input, body})

            Req.Test.json(conn, %{
              "data" => %{"id" => "run", "status" => "READY", "defaultDatasetId" => "ds"}
            })

          conn.request_path == "/v2/actor-runs/run" ->
            Req.Test.json(conn, %{
              "data" => %{"id" => "run", "status" => "SUCCEEDED", "defaultDatasetId" => "ds"}
            })

          conn.request_path == "/v2/datasets/ds/items" ->
            Req.Test.json(conn, [])

          true ->
            flunk("unexpected #{conn.method} #{conn.request_path}")
        end
      end)

      _ = ApifyAdapter.fetch_posts(account(%{platform: "twitter", handle: "acme"}))

      assert_receive {^ref, :run_input, body}
      decoded = Jason.decode!(body)
      assert decoded["from"] == "acme"
      # Existing keys must still be present - other actors ignore unknown
      # keys, so this addition is safe.
      assert decoded["handle"] == "acme"
      assert decoded["username"] == "acme"
      assert decoded["screenName"] == "acme"
    end
  end

  describe "fetch_metrics_for_post/2 (Phase 17.7 all-platforms via Apify)" do
    @kaito "kaitoeasyapi~twitter-x-data-tweet-scraper-pay-per-result-cheapest"
    @fb_post_actor "apify~facebook-posts-scraper"

    setup do
      # Phase 17.7 picks the per-platform actor for metrics from
      # `:metrics_actors` first; the slice ships overrides only
      # for platforms whose handle-scraping actor (from 17.1) is
      # not the right per-post actor (Facebook, where the page
      # scraper is not the post scraper). All other platforms fall
      # through to the existing `:actors` map.
      put_cfg(
        cfg()
        |> Keyword.put(
          :actors,
          Map.merge(cfg()[:actors], %{"twitter" => @kaito})
        )
        |> Keyword.put(:metrics_actors, %{
          "facebook" => @fb_post_actor
        })
      )

      :ok
    end

    test "twitter happy path returns unified engagement shape with non-nil counts" do
      items = [
        %{
          "id" => "1900000",
          "text" => "looked up by id",
          "url" => "https://x.com/i/status/1900000",
          "likeCount" => 42,
          "replyCount" => 3,
          "retweetCount" => 7,
          "quoteCount" => 2,
          "viewCount" => 5_000,
          "createdAt" => "2026-04-22T12:00:00.000Z"
        }
      ]

      stage_success(items, @kaito)

      assert {:ok, metrics} =
               ApifyAdapter.fetch_metrics_for_post(
                 "twitter",
                 "https://x.com/i/status/1900000"
               )

      assert metrics["likes"] == 42
      assert metrics["comments"] == 3
      assert metrics["shares"] == 7
      assert metrics["views"] == 5_000
    end

    test "linkedin happy path normalises numLikes/numComments/numShares shape" do
      items = [
        %{
          "urn" => "urn:li:activity:111",
          "url" => "https://linkedin.com/posts/111",
          "numLikes" => 55,
          "numComments" => 4,
          "numShares" => 2
        }
      ]

      stage_success(items, "apify~linkedin-post-scraper")

      assert {:ok, metrics} =
               ApifyAdapter.fetch_metrics_for_post(
                 "linkedin",
                 "https://linkedin.com/posts/111"
               )

      assert metrics["likes"] == 55
      assert metrics["comments"] == 4
      assert metrics["shares"] == 2
    end

    test "facebook happy path uses the metrics_actors override for the post scraper" do
      items = [
        %{
          "postId" => "fb_9001",
          "url" => "https://facebook.com/posts/9001",
          "likes" => 80,
          "comments" => 12,
          "shares" => 4
        }
      ]

      stage_success(items, @fb_post_actor)

      assert {:ok, metrics} =
               ApifyAdapter.fetch_metrics_for_post(
                 "facebook",
                 "https://facebook.com/posts/9001"
               )

      assert metrics["likes"] == 80
      assert metrics["comments"] == 12
      assert metrics["shares"] == 4
    end

    test "instagram happy path normalises image/reel shape with views" do
      items = [
        %{
          "id" => "ig_7777",
          "url" => "https://instagram.com/p/7777",
          "likesCount" => 250,
          "commentsCount" => 30,
          "playCount" => 9_000
        }
      ]

      stage_success(items, "apify~instagram-scraper")

      assert {:ok, metrics} =
               ApifyAdapter.fetch_metrics_for_post(
                 "instagram",
                 "https://instagram.com/p/7777"
               )

      assert metrics["likes"] == 250
      assert metrics["comments"] == 30
      assert metrics["views"] == 9_000
    end

    test "reddit happy path maps score and num_comments to the unified shape" do
      items = [
        %{
          "id" => "reddit_abc",
          "url" => "https://reddit.com/r/foo/comments/abc",
          "score" => 123,
          "num_comments" => 17
        }
      ]

      stage_success(items, "trudax~reddit-scraper")

      assert {:ok, metrics} =
               ApifyAdapter.fetch_metrics_for_post(
                 "reddit",
                 "https://reddit.com/r/foo/comments/abc"
               )

      assert metrics["likes"] == 123
      assert metrics["comments"] == 17
    end

    test "youtube happy path captures viewCount + likes + comments" do
      items = [
        %{
          "id" => "yt_AbCd",
          "url" => "https://youtube.com/watch?v=AbCd",
          "viewCount" => 50_000,
          "likes" => 1_500,
          "comments" => 200
        }
      ]

      stage_success(items, "apify~youtube-scraper")

      assert {:ok, metrics} =
               ApifyAdapter.fetch_metrics_for_post(
                 "youtube",
                 "https://youtube.com/watch?v=AbCd"
               )

      assert metrics["likes"] == 1_500
      assert metrics["comments"] == 200
      assert metrics["views"] == 50_000
    end

    test "missing counts default to nil (not zero) so corrective-loop signal is honest" do
      items = [
        %{
          "id" => "1900001",
          "url" => "https://x.com/i/status/1900001",
          "likeCount" => 10,
          # no replyCount/retweetCount/viewCount
          "createdAt" => "2026-04-22T12:00:00.000Z"
        }
      ]

      stage_success(items, @kaito)

      assert {:ok, metrics} =
               ApifyAdapter.fetch_metrics_for_post(
                 "twitter",
                 "https://x.com/i/status/1900001"
               )

      assert metrics["likes"] == 10
      assert metrics["comments"] == nil
      assert metrics["shares"] == nil
      assert metrics["views"] == nil
    end

    test "twitter input shape: startUrls=[<post_url>] + maxItems=>1 against the configured actor" do
      ref = make_ref()
      test_pid = self()

      Req.Test.stub(@stub_key, fn conn ->
        cond do
          conn.method == "POST" and String.starts_with?(conn.request_path, "/v2/acts/") ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {ref, :run_input, conn.request_path, body})

            Req.Test.json(conn, %{
              "data" => %{"id" => "rmx", "status" => "READY", "defaultDatasetId" => "dmx"}
            })

          conn.request_path == "/v2/actor-runs/rmx" ->
            Req.Test.json(conn, %{
              "data" => %{"id" => "rmx", "status" => "SUCCEEDED", "defaultDatasetId" => "dmx"}
            })

          conn.request_path == "/v2/datasets/dmx/items" ->
            Req.Test.json(conn, [
              %{
                "id" => "1888777",
                "url" => "https://x.com/i/status/1888777",
                "createdAt" => "2026-04-22T12:00:00.000Z",
                "likeCount" => 0
              }
            ])
        end
      end)

      assert {:ok, _} =
               ApifyAdapter.fetch_metrics_for_post(
                 "twitter",
                 "https://x.com/i/status/1888777"
               )

      assert_receive {^ref, :run_input, path, raw_body}
      assert path == "/v2/acts/#{@kaito}/runs"

      decoded = Jason.decode!(raw_body)
      assert decoded["maxItems"] == 1
      assert decoded["startUrls"] == ["https://x.com/i/status/1888777"]
    end

    test "linkedin input shape: urls=[<post_url>] (no startUrls)" do
      ref = make_ref()
      test_pid = self()

      Req.Test.stub(@stub_key, fn conn ->
        cond do
          conn.method == "POST" and String.starts_with?(conn.request_path, "/v2/acts/") ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {ref, :run_input, body})

            Req.Test.json(conn, %{
              "data" => %{"id" => "rli", "status" => "READY", "defaultDatasetId" => "dli"}
            })

          conn.request_path == "/v2/actor-runs/rli" ->
            Req.Test.json(conn, %{
              "data" => %{"id" => "rli", "status" => "SUCCEEDED", "defaultDatasetId" => "dli"}
            })

          conn.request_path == "/v2/datasets/dli/items" ->
            Req.Test.json(conn, [%{"urn" => "u1", "url" => "u1", "numLikes" => 1}])
        end
      end)

      assert {:ok, _} =
               ApifyAdapter.fetch_metrics_for_post(
                 "linkedin",
                 "https://linkedin.com/posts/111"
               )

      assert_receive {^ref, :run_input, raw_body}
      decoded = Jason.decode!(raw_body)
      assert decoded["urls"] == ["https://linkedin.com/posts/111"]
      refute Map.has_key?(decoded, "startUrls")
    end

    test "instagram input shape: directUrls=[<permalink>] (no startUrls)" do
      ref = make_ref()
      test_pid = self()

      Req.Test.stub(@stub_key, fn conn ->
        cond do
          conn.method == "POST" and String.starts_with?(conn.request_path, "/v2/acts/") ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {ref, :run_input, body})

            Req.Test.json(conn, %{
              "data" => %{"id" => "rig", "status" => "READY", "defaultDatasetId" => "dig"}
            })

          conn.request_path == "/v2/actor-runs/rig" ->
            Req.Test.json(conn, %{
              "data" => %{"id" => "rig", "status" => "SUCCEEDED", "defaultDatasetId" => "dig"}
            })

          conn.request_path == "/v2/datasets/dig/items" ->
            Req.Test.json(conn, [%{"id" => "ig1", "url" => "u", "likesCount" => 1}])
        end
      end)

      assert {:ok, _} =
               ApifyAdapter.fetch_metrics_for_post(
                 "instagram",
                 "https://instagram.com/p/7777"
               )

      assert_receive {^ref, :run_input, raw_body}
      decoded = Jason.decode!(raw_body)
      assert decoded["directUrls"] == ["https://instagram.com/p/7777"]
      refute Map.has_key?(decoded, "startUrls")
    end

    test "missing token returns {:error, :not_configured} with zero HTTP" do
      put_cfg(Keyword.put(cfg(), :token, nil))

      test_pid = self()

      Req.Test.stub(@stub_key, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no HTTP expected when apify token is missing"
      end)

      assert {:error, :not_configured} =
               ApifyAdapter.fetch_metrics_for_post("twitter", "https://x.com/i/status/1")

      refute_received :unexpected_http
    end

    test "unsupported platform (no actor mapped) returns {:error, :unsupported_platform}" do
      put_cfg(
        cfg()
        |> Keyword.put(:actors, %{})
        |> Keyword.put(:metrics_actors, %{})
      )

      test_pid = self()

      Req.Test.stub(@stub_key, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no HTTP expected when no actor is mapped"
      end)

      assert {:error, :unsupported_platform} =
               ApifyAdapter.fetch_metrics_for_post("twitter", "https://x.com/i/status/1")

      refute_received :unexpected_http
    end

    test "transient HTTP error on run creation returns classified error" do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, JSON.encode!(%{"error" => "boom"}))
      end)

      assert {:error, {:transient, 500, _}} =
               ApifyAdapter.fetch_metrics_for_post("twitter", "https://x.com/i/status/1")
    end

    test "permanent HTTP error on run creation returns classified error" do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(401, JSON.encode!(%{"error" => "auth"}))
      end)

      assert {:error, {:http_error, 401, _}} =
               ApifyAdapter.fetch_metrics_for_post("twitter", "https://x.com/i/status/1")
    end

    test "actor run FAILED is propagated as :apify_run_failed (not zero-filled)" do
      Req.Test.stub(@stub_key, fn conn ->
        cond do
          conn.method == "POST" and String.starts_with?(conn.request_path, "/v2/acts/") ->
            Req.Test.json(conn, %{
              "data" => %{"id" => "fr", "status" => "READY", "defaultDatasetId" => "fd"}
            })

          conn.request_path == "/v2/actor-runs/fr" ->
            Req.Test.json(conn, %{
              "data" => %{"id" => "fr", "status" => "FAILED", "defaultDatasetId" => "fd"}
            })
        end
      end)

      log =
        capture_log(fn ->
          assert {:error, {:apify_run_failed, "FAILED"}} =
                   ApifyAdapter.fetch_metrics_for_post("twitter", "https://x.com/i/status/1")
        end)

      assert log =~ "FAILED"
    end

    test "empty dataset returns :apify_parse_failure (not zero-filled metrics)" do
      stage_success([], @kaito)

      assert {:error, :apify_parse_failure} =
               ApifyAdapter.fetch_metrics_for_post("twitter", "https://x.com/i/status/1")
    end
  end
end
