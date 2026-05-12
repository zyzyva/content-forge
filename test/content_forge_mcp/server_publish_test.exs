defmodule ContentForgeMCP.ServerPublishTest do
  @moduledoc """
  Phase 16-tail PR-rework coverage for the four publishing MCP
  tools. Asserts Authorization gates fire (`cf_publish_text`
  requires `:submitter`, `cf_publish_video` requires `:owner`),
  the two-turn Confirmation flow on `cf_publish_video` works,
  `cf_platform_status` reports the connection status, and
  `cf_list_published_posts` scopes to a product.
  """

  use ContentForge.DataCase, async: false

  alias ContentForge.ContentGeneration
  alias ContentForge.Products
  alias ContentForge.Publishing
  alias ContentForge.Publishing.VideoJob
  alias ContentForgeMCP.Server

  # --- stubs (mirror multi_platform_test) -----------------------------------

  defmodule TwitterOk do
    def post(_text, _creds, _opts),
      do: {:ok, %{post_id: "tw_1", post_url: "https://twitter.com/p/tw_1"}}
  end

  defmodule LinkedInOk do
    def post(_text, _creds, _opts),
      do: {:ok, %{post_id: "li_1", post_url: "https://linkedin.com/posts/li_1"}}
  end

  defmodule FacebookOk do
    def post(_text, _creds, _opts),
      do: {:ok, %{post_id: "fb_1", post_url: "https://facebook.com/p/fb_1"}}
  end

  defmodule RedditOk do
    def post(_text, _creds, _opts),
      do: {:ok, %{post_id: "rd_1", post_url: "https://reddit.com/r/x/comments/rd_1"}}
  end

  defmodule YouTubeOk do
    def upload(_path, _creds, _opts),
      do: {:ok, %{post_id: "yt_1", post_url: "https://youtube.com/watch?v=yt_1"}}
  end

  setup do
    Application.put_env(:content_forge, :twitter_client, TwitterOk)
    Application.put_env(:content_forge, :linkedin_client, LinkedInOk)
    Application.put_env(:content_forge, :facebook_client, FacebookOk)
    Application.put_env(:content_forge, :reddit_client, RedditOk)
    Application.put_env(:content_forge, :youtube_client, YouTubeOk)

    sentinel = Path.join(System.tmp_dir(), "cf_test_video_#{System.unique_integer()}.mp4")
    File.write!(sentinel, <<0, 1, 2, 3>>)

    Application.put_env(:content_forge, :r2_downloader, fn _ -> {:ok, sentinel} end)

    Application.put_env(
      :content_forge,
      :video_staging,
      fn _, video_job, platform ->
        {:ok, "https://r2.test/video_distribution/#{video_job.id}/#{platform}.mp4"}
      end
    )

    # Default MCP authz to "owner" so write tools succeed unless a
    # specific test demotes the role. (This mirrors the v1
    # production default: the MCP transport is the authz
    # boundary in single-operator stdio usage.)
    Application.put_env(:content_forge, :mcp_authz, default_role: "owner")

    on_exit(fn ->
      Application.delete_env(:content_forge, :twitter_client)
      Application.delete_env(:content_forge, :linkedin_client)
      Application.delete_env(:content_forge, :facebook_client)
      Application.delete_env(:content_forge, :reddit_client)
      Application.delete_env(:content_forge, :youtube_client)
      Application.delete_env(:content_forge, :r2_downloader)
      Application.delete_env(:content_forge, :video_staging)
      Application.delete_env(:content_forge, :mcp_authz)
      File.rm(sentinel)
    end)

    {:ok, product} = build_product()
    %{product: product}
  end

  defp build_product(opts \\ []) do
    targets = Keyword.get(opts, :targets, full_targets())

    Products.create_product(%{
      name: "MCP Publish #{System.unique_integer()}",
      voice_profile: "professional",
      publishing_targets: targets
    })
  end

  defp full_targets do
    %{
      "twitter" => %{"access_token" => "tw-tok"},
      "linkedin" => %{"access_token" => "li-tok", "person_id" => "urn:li:person:1"},
      "facebook" => %{"access_token" => "fb-tok", "page_id" => "fb-page"},
      "instagram" => %{"access_token" => "fb-tok", "account_id" => "ig-acct"},
      "reddit" => %{"access_token" => "rd-tok", "subreddit" => "test"},
      "youtube" => %{"access_token" => "yt-tok", "privacy" => "private"}
    }
  end

  defp insert_video_job(product) do
    {:ok, draft} =
      ContentGeneration.create_draft(%{
        product_id: product.id,
        content: "# Demo Title\n\nDemo body content.",
        platform: "youtube",
        content_type: "video_script",
        generating_model: "stub",
        status: "approved"
      })

    %VideoJob{}
    |> VideoJob.changeset(%{
      draft_id: draft.id,
      product_id: product.id,
      status: "encoded",
      per_step_r2_keys: %{"final" => "videos/x.mp4"},
      published_platforms: []
    })
    |> Repo.insert!()
  end

  # --- cf_publish_text ------------------------------------------------------

  describe "cf_publish_text" do
    test "happy path: returns a result map with the right shape", %{product: product} do
      {:ok, body} =
        Server.handle_tool_call("cf_publish_text", %{
          "product_id" => product.id,
          "text" => "hello from mcp",
          "platforms" => "[\"twitter\",\"linkedin\"]"
        })

      assert body.product_id == product.id
      assert body.total_attempted == 2
      assert body.total_succeeded == 2
      assert body.results["twitter"][:status] == "success"
      assert body.results["linkedin"][:status] == "success"
    end

    test ":submitter is the minimum role; :viewer is forbidden", %{product: product} do
      Application.put_env(:content_forge, :mcp_authz, default_role: "viewer")

      {:error, %{code: code}} =
        Server.handle_tool_call("cf_publish_text", %{
          "product_id" => product.id,
          "text" => "denied"
        })

      assert code == "forbidden"
    end

    test "submitter role passes the gate", %{product: product} do
      Application.put_env(:content_forge, :mcp_authz, default_role: "submitter")

      assert {:ok, _} =
               Server.handle_tool_call("cf_publish_text", %{
                 "product_id" => product.id,
                 "text" => "submitter",
                 "platforms" => "[\"twitter\"]"
               })
    end
  end

  # --- cf_publish_text Draft-pipeline integration (16.7) --------------------

  describe "cf_publish_text Draft-pipeline integration" do
    test "auto-creates one Draft per platform with the documented attrs", %{product: product} do
      {:ok, body} =
        Server.handle_tool_call("cf_publish_text", %{
          "product_id" => product.id,
          "text" => "agent-authored body",
          "sender_identity" => "agent-alice",
          "platforms" => "[\"twitter\",\"linkedin\"]"
        })

      assert is_map(body.drafts)
      assert Map.keys(body.drafts) |> Enum.sort() == ["linkedin", "twitter"]

      twitter_draft = ContentGeneration.get_draft(body.drafts["twitter"])
      linkedin_draft = ContentGeneration.get_draft(body.drafts["linkedin"])

      assert twitter_draft.product_id == product.id
      assert twitter_draft.platform == "twitter"
      assert twitter_draft.content_type == "post"
      assert twitter_draft.angle == "direct"
      assert twitter_draft.content == "agent-authored body"
      assert twitter_draft.status == "approved"
      assert twitter_draft.generating_model == "agent:cf_publish_text:agent-alice"

      assert linkedin_draft.platform == "linkedin"
      assert linkedin_draft.id != twitter_draft.id
    end

    test "creates one PublishedPost row per platform with the right draft_id", %{
      product: product
    } do
      {:ok, body} =
        Server.handle_tool_call("cf_publish_text", %{
          "product_id" => product.id,
          "text" => "tracked text",
          "platforms" => "[\"twitter\",\"linkedin\"]"
        })

      rows = Publishing.list_published_posts(product_id: product.id)
      assert length(rows) == 2

      twitter_row = Enum.find(rows, &(&1.platform == "twitter"))
      linkedin_row = Enum.find(rows, &(&1.platform == "linkedin"))

      assert twitter_row.draft_id == body.drafts["twitter"]
      assert linkedin_row.draft_id == body.drafts["linkedin"]
    end

    test "caller-supplied angle propagates onto each Draft row", %{product: product} do
      {:ok, body} =
        Server.handle_tool_call("cf_publish_text", %{
          "product_id" => product.id,
          "text" => "with angle",
          "angle" => "humor",
          "platforms" => "[\"twitter\"]"
        })

      draft = ContentGeneration.get_draft(body.drafts["twitter"])
      assert draft.angle == "humor"
    end

    test "missing sender_identity falls back to 'unknown' in generating_model", %{
      product: product
    } do
      {:ok, body} =
        Server.handle_tool_call("cf_publish_text", %{
          "product_id" => product.id,
          "text" => "anon",
          "platforms" => "[\"twitter\"]"
        })

      draft = ContentGeneration.get_draft(body.drafts["twitter"])
      assert draft.generating_model == "agent:cf_publish_text:unknown"
    end

    test "explicit draft_id reuses the same Draft across platforms (no auto-create)", %{
      product: product
    } do
      {:ok, draft} =
        ContentGeneration.create_draft(%{
          product_id: product.id,
          content: "pre-existing body",
          platform: "twitter",
          content_type: "post",
          generating_model: "agent:cf_publish_text:pre",
          angle: "direct",
          status: "approved"
        })

      {:ok, body} =
        Server.handle_tool_call("cf_publish_text", %{
          "product_id" => product.id,
          "text" => "pre-existing body",
          "draft_id" => draft.id,
          "platforms" => "[\"twitter\",\"linkedin\"]"
        })

      assert body.drafts["twitter"] == draft.id
      assert body.drafts["linkedin"] == draft.id

      rows = Publishing.list_published_posts(product_id: product.id)
      assert Enum.all?(rows, &(&1.draft_id == draft.id))
    end

    test "idempotent re-call with the same draft_id skips already-published platforms",
         %{product: product} do
      {:ok, draft} =
        ContentGeneration.create_draft(%{
          product_id: product.id,
          content: "body",
          platform: "twitter",
          content_type: "post",
          generating_model: "agent:cf_publish_text:agent",
          angle: "direct",
          status: "approved"
        })

      {:ok, first} =
        Server.handle_tool_call("cf_publish_text", %{
          "product_id" => product.id,
          "text" => "body",
          "draft_id" => draft.id,
          "platforms" => "[\"twitter\"]"
        })

      assert first.total_attempted == 1
      assert first.results["twitter"][:status] == "success"

      {:ok, second} =
        Server.handle_tool_call("cf_publish_text", %{
          "product_id" => product.id,
          "text" => "body",
          "draft_id" => draft.id,
          "platforms" => "[\"twitter\",\"linkedin\"]"
        })

      assert second.total_attempted == 1
      assert second.results["linkedin"][:status] == "success"
      assert second.results["twitter"][:status] == "skipped_already_published"

      rows = Publishing.list_published_posts(product_id: product.id)
      platforms = rows |> Enum.map(& &1.platform) |> Enum.sort()
      assert platforms == ["linkedin", "twitter"]
    end

    test "no draft_id param: each re-call creates fresh drafts and duplicates publishes",
         %{product: product} do
      {:ok, first} =
        Server.handle_tool_call("cf_publish_text", %{
          "product_id" => product.id,
          "text" => "no idempotency",
          "platforms" => "[\"twitter\"]"
        })

      {:ok, second} =
        Server.handle_tool_call("cf_publish_text", %{
          "product_id" => product.id,
          "text" => "no idempotency",
          "platforms" => "[\"twitter\"]"
        })

      refute first.drafts["twitter"] == second.drafts["twitter"]
      rows = Publishing.list_published_posts(product_id: product.id)
      assert length(rows) == 2
    end

    test "explicit draft_id from another product is rejected", %{product: product} do
      {:ok, other_product} =
        Products.create_product(%{
          name: "Other Product #{System.unique_integer()}",
          voice_profile: "professional"
        })

      {:ok, foreign_draft} =
        ContentGeneration.create_draft(%{
          product_id: other_product.id,
          content: "x",
          platform: "twitter",
          content_type: "post",
          generating_model: "agent:cf_publish_text:x",
          status: "approved"
        })

      {:error, %{code: code}} =
        Server.handle_tool_call("cf_publish_text", %{
          "product_id" => product.id,
          "text" => "x",
          "draft_id" => foreign_draft.id,
          "platforms" => "[\"twitter\"]"
        })

      assert code == "not_found"
    end
  end

  describe "MultiPlatform moduledoc no longer claims draft_id will be made nullable" do
    test "moduledoc does NOT promise to make PublishedPost.draft_id nullable" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} =
        Code.fetch_docs(ContentForge.Publishing.MultiPlatform)

      refute moduledoc =~ "make `draft_id` optional"
      refute moduledoc =~ "Making `draft_id` optional"
      refute moduledoc =~ "deferred schema follow-up"
      # Positive: it should now point at the 16.7 fix.
      assert moduledoc =~ "16.7"
    end
  end

  # --- cf_publish_video (two-turn confirmation) -----------------------------

  describe "cf_publish_video" do
    setup %{product: product} do
      video_job = insert_video_job(product)
      %{product: product, video_job: video_job}
    end

    test "first call returns a confirmation_required envelope with an echo phrase", %{
      product: product,
      video_job: video_job
    } do
      {:ok, body} =
        Server.handle_tool_call("cf_publish_video", %{
          "video_job_id" => video_job.id,
          "product_id" => product.id,
          "platforms" => "[\"youtube\",\"twitter\"]"
        })

      assert body.confirmation_required == true
      assert is_binary(body.echo_phrase)
      assert is_binary(body.expires_at)
      assert body.platforms == ["youtube", "twitter"]
      assert body.preview.product_id == product.id
    end

    test "second call with the echo phrase enqueues the fan-out", %{
      product: product,
      video_job: video_job
    } do
      {:ok, first} =
        Server.handle_tool_call("cf_publish_video", %{
          "video_job_id" => video_job.id,
          "product_id" => product.id,
          "platforms" => "[\"youtube\",\"twitter\"]"
        })

      {:ok, body} =
        Server.handle_tool_call("cf_publish_video", %{
          "video_job_id" => video_job.id,
          "product_id" => product.id,
          "platforms" => "[\"youtube\",\"twitter\"]",
          "confirm" => first.echo_phrase
        })

      assert body.video_job_id == video_job.id
      assert body.total_attempted == 2
      assert body.total_succeeded == 2
      assert "youtube" in body.all_published_platforms
      assert "twitter" in body.all_published_platforms
    end

    test "second call with a wrong echo phrase returns :confirmation_mismatch", %{
      product: product,
      video_job: video_job
    } do
      {:ok, _first} =
        Server.handle_tool_call("cf_publish_video", %{
          "video_job_id" => video_job.id,
          "product_id" => product.id
        })

      {:error, %{code: code}} =
        Server.handle_tool_call("cf_publish_video", %{
          "video_job_id" => video_job.id,
          "product_id" => product.id,
          "confirm" => "not-the-right-phrase"
        })

      assert code in ["confirmation_not_found", "confirmation_mismatch"]
    end

    test ":owner is the minimum role; :submitter is forbidden", %{
      product: product,
      video_job: video_job
    } do
      Application.put_env(:content_forge, :mcp_authz, default_role: "submitter")

      {:error, %{code: code}} =
        Server.handle_tool_call("cf_publish_video", %{
          "video_job_id" => video_job.id,
          "product_id" => product.id
        })

      assert code == "forbidden"
    end
  end

  # --- cf_platform_status ---------------------------------------------------

  describe "cf_platform_status" do
    test "returns connected_count + connected list + per-platform status", %{product: product} do
      {:ok, body} = Server.handle_tool_call("cf_platform_status", %{"product_id" => product.id})

      assert body.product_id == product.id
      assert is_integer(body.connected_count)
      assert is_list(body.connected)
      assert "twitter" in body.connected
      assert is_list(body.platforms)
    end

    test "unknown product returns the structured not_found envelope" do
      {:error, %{code: code}} =
        Server.handle_tool_call("cf_platform_status", %{
          "product_id" => "00000000-0000-0000-0000-000000000000"
        })

      assert code == "not_found"
    end
  end

  # --- cf_list_published_posts ----------------------------------------------

  describe "cf_list_published_posts" do
    test "lists posts scoped to the product; cross-product posts not visible",
         %{product: product} do
      {:ok, other} = build_product()

      # Seed one PublishedPost per product. Need a draft for FK.
      {:ok, draft} =
        ContentGeneration.create_draft(%{
          product_id: product.id,
          content: "x",
          platform: "twitter",
          content_type: "post",
          generating_model: "stub",
          status: "approved"
        })

      {:ok, _ours} =
        Publishing.create_published_post(%{
          product_id: product.id,
          draft_id: draft.id,
          platform: "twitter",
          platform_post_id: "ours_1",
          platform_post_url: "https://twitter.com/ours_1",
          posted_at: DateTime.utc_now()
        })

      {:ok, other_draft} =
        ContentGeneration.create_draft(%{
          product_id: other.id,
          content: "y",
          platform: "twitter",
          content_type: "post",
          generating_model: "stub",
          status: "approved"
        })

      {:ok, _theirs} =
        Publishing.create_published_post(%{
          product_id: other.id,
          draft_id: other_draft.id,
          platform: "twitter",
          platform_post_id: "theirs_1",
          platform_post_url: "https://twitter.com/theirs_1",
          posted_at: DateTime.utc_now()
        })

      {:ok, body} =
        Server.handle_tool_call("cf_list_published_posts", %{"product_id" => product.id})

      assert body.product_id == product.id
      assert body.count == 1
      assert hd(body.posts).platform_post_id == "ours_1"
    end

    test "honors the platform filter", %{product: product} do
      {:ok, draft} =
        ContentGeneration.create_draft(%{
          product_id: product.id,
          content: "x",
          platform: "twitter",
          content_type: "post",
          generating_model: "stub",
          status: "approved"
        })

      for platform <- ["twitter", "linkedin"] do
        {:ok, _} =
          Publishing.create_published_post(%{
            product_id: product.id,
            draft_id: draft.id,
            platform: platform,
            platform_post_id: "p_#{platform}",
            platform_post_url: "https://x/#{platform}",
            posted_at: DateTime.utc_now()
          })
      end

      {:ok, body} =
        Server.handle_tool_call("cf_list_published_posts", %{
          "product_id" => product.id,
          "platform" => "linkedin"
        })

      assert body.count == 1
      assert hd(body.posts).platform == "linkedin"
    end
  end
end
