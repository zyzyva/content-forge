defmodule ContentForge.Publishing.MultiPlatformTest do
  @moduledoc """
  Phase 16-tail PR-rework coverage for the multi-platform
  publishing fan-out. Pre-rework MultiPlatform sat at 0.93%
  coverage.

  Each platform client (Twitter / LinkedIn / Facebook / Reddit /
  YouTube) is swapped via Application config for an in-process
  stub. The R2 download path and the per-platform staging
  upload path are each behind their own Application env seam so
  tests don't touch the network or the filesystem.
  """

  use ContentForge.DataCase, async: false

  alias ContentForge.Products
  alias ContentForge.Publishing
  alias ContentForge.Publishing.MultiPlatform
  alias ContentForge.Publishing.VideoJob

  # --- per-platform stubs ---------------------------------------------------

  defmodule TwitterOk do
    def post(_text, _creds, _opts),
      do: {:ok, %{post_id: "tw_1", post_url: "https://twitter.com/p/tw_1"}}
  end

  defmodule TwitterErr do
    def post(_text, _creds, _opts), do: {:error, "twitter 5xx transient"}
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

  defmodule TwitterTrackOk do
    def post(_text, _creds, _opts) do
      send(self(), {__MODULE__, :called})
      {:ok, %{post_id: "tw_track", post_url: "https://twitter.com/tw_track"}}
    end
  end

  setup do
    Application.put_env(:content_forge, :twitter_client, TwitterOk)
    Application.put_env(:content_forge, :linkedin_client, LinkedInOk)
    Application.put_env(:content_forge, :facebook_client, FacebookOk)
    Application.put_env(:content_forge, :reddit_client, RedditOk)
    Application.put_env(:content_forge, :youtube_client, YouTubeOk)

    # Stub R2 download to return a local sentinel path without
    # hitting Storage / Req.
    sentinel = Path.join(System.tmp_dir(), "cf_test_video_#{System.unique_integer()}.mp4")
    File.write!(sentinel, <<0, 1, 2, 3>>)

    Application.put_env(
      :content_forge,
      :r2_downloader,
      fn _key -> {:ok, sentinel} end
    )

    # Stub per-platform staging upload to return a deterministic
    # presigned URL without hitting Storage / ExAws.
    Application.put_env(
      :content_forge,
      :video_staging,
      fn _local_path, video_job, platform ->
        {:ok, "https://r2.test/video_distribution/#{video_job.id}/#{platform}.mp4"}
      end
    )

    on_exit(fn ->
      Application.delete_env(:content_forge, :twitter_client)
      Application.delete_env(:content_forge, :linkedin_client)
      Application.delete_env(:content_forge, :facebook_client)
      Application.delete_env(:content_forge, :reddit_client)
      Application.delete_env(:content_forge, :youtube_client)
      Application.delete_env(:content_forge, :r2_downloader)
      Application.delete_env(:content_forge, :video_staging)
      File.rm(sentinel)
    end)

    {:ok, product} = build_product()
    %{product: product}
  end

  defp build_product(opts \\ []) do
    targets = Keyword.get(opts, :targets, all_connected_targets())

    Products.create_product(%{
      name: "MultiPlatform Co #{System.unique_integer()}",
      voice_profile: "professional",
      publishing_targets: targets
    })
  end

  defp all_connected_targets do
    %{
      "twitter" => %{"access_token" => "tw-tok"},
      "linkedin" => %{
        "access_token" => "li-tok",
        "person_id" => "urn:li:person:1"
      },
      "facebook" => %{"access_token" => "fb-tok", "page_id" => "fb-page"},
      "instagram" => %{"access_token" => "fb-tok", "account_id" => "ig-acct"},
      "reddit" => %{"access_token" => "rd-tok", "subreddit" => "test"},
      "youtube" => %{"access_token" => "yt-tok", "privacy" => "private"}
    }
  end

  # --- text fan-out ---------------------------------------------------------

  describe "publish_text/4 per-platform fan-out" do
    test "publishes to every connected platform; returns per-platform ok tuples",
         %{product: product} do
      results =
        MultiPlatform.publish_text(product, "hello world", "https://img/x.png", [
          "twitter",
          "linkedin",
          "reddit",
          "facebook",
          "instagram"
        ])

      assert {:ok, %{post_id: "tw_1"}} = results["twitter"]
      assert {:ok, %{post_id: "li_1"}} = results["linkedin"]
      assert {:ok, %{post_id: "rd_1"}} = results["reddit"]
      assert {:ok, %{post_id: "fb_1"}} = results["facebook"]
      assert {:ok, %{post_id: "fb_1"}} = results["instagram"]
    end

    test "does NOT write PublishedPost rows on the free-form text path (moduledoc contract)",
         %{product: product} do
      # `publish_text/4` is the MCP / OpenClaw surface for
      # draft-less posts; PublishedPost requires draft_id and is
      # intentionally skipped here. The moduledoc spells this
      # out; this test pins the documented behavior so a future
      # schema change is intentional rather than incidental.
      _ =
        MultiPlatform.publish_text(product, "hello world", "https://img/x.png", [
          "twitter",
          "linkedin",
          "reddit",
          "facebook",
          "instagram"
        ])

      assert Publishing.list_published_posts(product_id: product.id) == []
    end

    test "skips platforms with no credentials silently" do
      targets = %{"twitter" => %{"access_token" => "tw-tok"}}
      {:ok, product} = build_product(targets: targets)

      results = MultiPlatform.publish_text(product, "hi", nil, ["twitter", "linkedin", "reddit"])

      assert {:ok, %{post_id: "tw_1"}} = results["twitter"]
      refute Map.has_key?(results, "linkedin")
      refute Map.has_key?(results, "reddit")
    end

    test "facebook + instagram refuse without an image_url", %{product: product} do
      results = MultiPlatform.publish_text(product, "no image", nil, ["facebook", "instagram"])

      assert {:error, _} = results["facebook"]
      assert {:error, _} = results["instagram"]
    end
  end

  describe "publish_text/4 partial failure" do
    test "one platform errors; others land; no exception bubbles", %{product: product} do
      Application.put_env(:content_forge, :twitter_client, TwitterErr)

      results =
        MultiPlatform.publish_text(product, "partial test", "https://img/x.png", [
          "twitter",
          "linkedin",
          "reddit"
        ])

      assert {:error, msg} = results["twitter"]
      assert msg =~ "twitter"
      assert {:ok, %{post_id: "li_1"}} = results["linkedin"]
      assert {:ok, %{post_id: "rd_1"}} = results["reddit"]
    end
  end

  describe "publish_text/4 idempotency divergence (documented)" do
    test "re-running re-attempts the same platform; text path is not idempotent (per moduledoc)",
         %{product: product} do
      r1 = MultiPlatform.publish_text(product, "first", nil, ["twitter"])
      r2 = MultiPlatform.publish_text(product, "first", nil, ["twitter"])

      # Same call twice -> two successful attempts. Idempotency
      # divergence between text-fan-out (not idempotent) and
      # video-fan-out (idempotent via
      # `video_job.published_platforms`) is documented in
      # MultiPlatform's moduledoc.
      assert {:ok, _} = r1["twitter"]
      assert {:ok, _} = r2["twitter"]
    end
  end

  # --- video fan-out --------------------------------------------------------

  describe "publish_video/3 fan-out" do
    setup %{product: product} do
      video_job = insert_video_job(product, %{per_step_r2_keys: %{"final" => "videos/x.mp4"}})
      %{product: product, video_job: video_job}
    end

    test "publishes to all video-supporting platforms and records PublishedPost rows for ALL FIVE (not YouTube-only)",
         %{product: product, video_job: video_job} do
      results =
        MultiPlatform.publish_video(
          video_job,
          ~w(youtube twitter facebook instagram linkedin reddit),
          product
        )

      assert {:ok, %{post_id: "yt_1"}} = results["youtube"]
      assert {:ok, %{post_id: "tw_1"}} = results["twitter"]
      assert {:ok, %{post_id: "fb_1"}} = results["facebook"]
      assert {:ok, %{post_id: "fb_1"}} = results["instagram"]
      assert {:ok, %{post_id: "li_1"}} = results["linkedin"]
      # Reddit does not support video upload via API.
      assert {:error, _} = results["reddit"]

      rows = Publishing.list_published_posts(product_id: product.id)

      assert Enum.sort(Enum.map(rows, & &1.platform)) ==
               ~w(facebook instagram linkedin twitter youtube)
    end

    test "idempotency: filters platforms already in video_job.published_platforms",
         %{product: product, video_job: video_job} do
      {:ok, video_job} =
        Publishing.update_video_job(video_job, %{published_platforms: ["twitter"]})

      Application.put_env(:content_forge, :twitter_client, TwitterTrackOk)

      results = MultiPlatform.publish_video(video_job, ~w(twitter linkedin), product)

      refute Map.has_key?(results, "twitter")
      assert {:ok, _} = results["linkedin"]
      refute_received {TwitterTrackOk, :called}
    end

    test "missing final video key returns {:error, :no_final_video_key} (no raise)",
         %{product: product, video_job: video_job} do
      {:ok, video_job} = Publishing.update_video_job(video_job, %{per_step_r2_keys: %{}})

      assert {:error, :no_final_video_key} =
               MultiPlatform.publish_video(video_job, ~w(youtube twitter), product)
    end

    test "partial failure: one platform errors, others land, no exception bubbles",
         %{product: product, video_job: video_job} do
      Application.put_env(:content_forge, :twitter_client, TwitterErr)

      results =
        MultiPlatform.publish_video(video_job, ~w(youtube twitter linkedin), product)

      assert {:ok, _} = results["youtube"]
      assert {:error, _} = results["twitter"]
      assert {:ok, _} = results["linkedin"]
    end
  end

  describe "connected_platforms/1 + platform_status/1" do
    test "returns the platforms whose targets include an access_token", %{product: product} do
      assert Enum.sort(MultiPlatform.connected_platforms(product)) ==
               ~w(facebook instagram linkedin reddit twitter youtube)
    end

    test "platforms without access_token are excluded" do
      {:ok, product} =
        build_product(targets: %{"twitter" => %{"access_token" => "tw-tok"}})

      assert MultiPlatform.connected_platforms(product) == ["twitter"]
    end

    test "platform_status/1 returns connected boolean per platform", %{product: product} do
      status = MultiPlatform.platform_status(product)
      assert Enum.all?(status, &Map.has_key?(&1, :connected))
      twitter = Enum.find(status, &(&1.platform == "twitter"))
      assert twitter.connected
    end
  end

  # --- helpers --------------------------------------------------------------

  defp insert_video_job(product, attrs) do
    {:ok, draft} =
      ContentForge.ContentGeneration.create_draft(%{
        product_id: product.id,
        content: "video script body",
        platform: "youtube",
        content_type: "video_script",
        generating_model: "stub",
        status: "approved"
      })

    base = %{
      draft_id: draft.id,
      product_id: product.id,
      status: "encoded",
      per_step_r2_keys: %{},
      published_platforms: []
    }

    %VideoJob{}
    |> VideoJob.changeset(Map.merge(base, attrs))
    |> Repo.insert!()
  end
end
