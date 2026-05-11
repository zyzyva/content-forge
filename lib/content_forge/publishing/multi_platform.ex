defmodule ContentForge.Publishing.MultiPlatform do
  @moduledoc """
  Multi-platform publishing dispatcher.

  Takes a product's `publishing_targets` (OAuth tokens + per-platform config)
  and a content payload (text or video), then fans out to each requested
  platform.

  ## PublishedPost tracking

  `PublishedPost` rows require a `draft_id` (schema NOT NULL), so
  tracking happens for any publish path that has an originating
  draft:

    * **Video fan-out** (`publish_video/3`): every successful per-platform
      publish writes a `PublishedPost` row threading
      `video_job.draft_id`. All five video-supporting platforms
      (YouTube, Twitter, Facebook, Instagram, LinkedIn) record.
      Reddit short-circuits without an attempt (no API video upload).
    * **Text fan-out** (`publish_text/4`): the MCP surface accepts
      free-form text with no originating draft, so the
      `PublishedPost` insert is intentionally skipped (logged at
      `:info`) when `draft_id` is `nil`. Callers that want
      tracking should publish through the draft-based publishing
      worker, not through `publish_text/4`. Making `draft_id`
      optional on `PublishedPost` is a deferred schema follow-up;
      the current behavior is documented here so a future test
      can pin it.

  ## Idempotency

  Video fan-out (`publish_video/3`) is idempotent: it filters out
  platforms already listed in `video_job.published_platforms`, so
  a repeat call after a partial-failure only re-attempts the
  platforms that did not succeed last time. The MCP tool layer
  (`cf_publish_video`) updates `published_platforms` after each
  successful per-platform publish, which closes the loop.

  Text fan-out (`publish_text/4`) is intentionally **not**
  idempotent in v1. A text post has no persistent identity (no
  `text_job` row), so a re-run of `publish_text` will re-attempt
  every platform regardless of whether the same text already
  landed. Callers that need at-most-once semantics should
  deduplicate at their own layer (e.g. by checking
  `Publishing.list_published_posts/1` for a matching
  `(product, platform, posted_at)` before invoking
  `publish_text/4` again). Adding a generic text-side
  idempotency marker is a follow-up if the operational pain
  shows up.
  """

  require Logger

  alias ContentForge.Products.Product
  alias ContentForge.Publishing

  # Phase 16-tail rework: per-platform client modules are looked
  # up via Application config so tests can swap in stubs without
  # standing up a full Req.Test plug-chain per platform. Defaults
  # match the production clients; the test suite swaps in
  # in-process stubs.
  defp twitter_client,
    do: Application.get_env(:content_forge, :twitter_client, ContentForge.Publishing.Twitter)

  defp linkedin_client,
    do: Application.get_env(:content_forge, :linkedin_client, ContentForge.Publishing.LinkedIn)

  defp facebook_client,
    do: Application.get_env(:content_forge, :facebook_client, ContentForge.Publishing.Facebook)

  defp reddit_client,
    do: Application.get_env(:content_forge, :reddit_client, ContentForge.Publishing.Reddit)

  defp youtube_client,
    do: Application.get_env(:content_forge, :youtube_client, ContentForge.Publishing.YouTube)

  @available_platforms ~w(twitter youtube facebook instagram linkedin reddit)

  @type post_result ::
          {:ok, %{platform: String.t(), post_id: String.t(), post_url: String.t()}}
          | {:error, String.t()}
  @type multi_result :: %{required(String.t()) => post_result()}

  # ============================================
  # Text Post Publishing
  # ============================================

  @doc """
  Publish a text post to one or more platforms.

  ## Args
    - `product` - the Product (loaded with `publishing_targets`)
    - `text` - post body
    - `image_url` - optional image URL (supported by Twitter, Facebook, LinkedIn)
    - `platforms` - list of platform names to publish to

  ## Returns
    `%{platform_name => {:ok, result} | {:error, reason}}`
  """
  @spec publish_text(Product.t(), String.t(), String.t() | nil, [String.t()]) :: multi_result()
  def publish_text(
        %Product{} = product,
        text,
        image_url \\ nil,
        platforms \\ @available_platforms
      )
      when is_binary(text) and is_list(platforms) do
    creds = build_credentials(product)

    platforms
    |> Enum.reject(&is_nil(creds[:"#{&1}_access_token"]))
    |> Enum.map(fn platform ->
      result = publish_to_platform(platform, text, image_url, creds, product)
      {platform, result}
    end)
    |> Map.new()
    |> tap_log_results("text post")
  end

  defp publish_to_platform("twitter" = platform, text, image_url, creds, product) do
    opts = maybe_image_opt(image_url)
    twitter_client().post(text, creds, opts) |> record_publish(product, nil, platform)
  end

  defp publish_to_platform("linkedin" = platform, text, image_url, creds, product) do
    linkedin_client().post(
      text,
      creds,
      maybe_image_opt(image_url) ++ maybe_organization_opt(product)
    )
    |> record_publish(product, nil, platform)
  end

  defp publish_to_platform("reddit" = platform, text, _image_url, creds, product) do
    subreddit = get_in(product.publishing_targets, ["reddit", "subreddit"]) || "all"
    opts = [subreddit: subreddit]
    reddit_client().post(text, creds, opts) |> record_publish(product, nil, platform)
  end

  defp publish_to_platform("facebook", _text, nil, _creds, _product),
    do: {:error, "Facebook posts require an image URL"}

  defp publish_to_platform("facebook" = platform, text, image_url, creds, product) do
    opts = [image_url: image_url] ++ maybe_page_opt(product)
    facebook_client().post(text, creds, opts) |> record_publish(product, nil, platform)
  end

  defp publish_to_platform("instagram", _text, nil, _creds, _product),
    do: {:error, "Instagram posts require an image URL"}

  defp publish_to_platform("instagram" = platform, text, image_url, creds, product) do
    opts = [image_url: image_url] ++ maybe_instagram_opt(product)

    facebook_client().post(text, creds, [{:target, :instagram} | opts])
    |> record_publish(product, nil, platform)
  end

  defp publish_to_platform("youtube" = _platform, _text, _image_url, _creds, _product) do
    {:error, "YouTube requires video content, not text. Use publish_video/3."}
  end

  defp publish_to_platform(platform, _text, _image_url, _creds, _product) do
    {:error, "Unknown platform: #{platform}"}
  end

  # ============================================
  # Video Job Publishing
  # ============================================

  @doc """
  Publish a completed VideoJob to one or more platforms.

  Downloads the final video from R2, uploads to each platform, and records
  results. Only platforms with valid OAuth credentials are attempted.

  ## Args
    - `video_job` - the VideoJob (must have `status: \"encoded\"` or `\"uploaded\"`)
    - `platforms` - list of platform names (default: all available)
    - `product` - the Product (loaded with `publishing_targets`)

  ## Returns
    `%{platform_name => {:ok, result} | {:error, reason}}`
  """
  @spec publish_video(Publishing.VideoJob.t(), [String.t()], Product.t()) ::
          multi_result() | {:error, term()}
  def publish_video(
        %Publishing.VideoJob{} = video_job,
        platforms \\ @available_platforms,
        %Product{} = product
      ) do
    case video_job.per_step_r2_keys["final"] do
      nil ->
        # Fan-out functions never raise; the caller logs +
        # classifies the error. The previous raise tripped the
        # `rescue` clauses in VideoProducer.distribute_to_other_platforms,
        # which swallowed every failure into `:ok`.
        Logger.error("publish_video: no final video key for job #{video_job.id}")
        {:error, :no_final_video_key}

      final_key ->
        do_publish_video(video_job, platforms, product, final_key)
    end
  end

  defp do_publish_video(video_job, platforms, product, final_key) do
    with {:ok, local_path} <- download_from_r2(final_key) do
      creds = build_credentials(product)
      already_published = video_job.published_platforms || []

      results =
        platforms
        |> Enum.reject(fn p ->
          is_nil(creds[:"#{p}_access_token"]) or p in already_published
        end)
        |> Enum.map(fn platform ->
          result = publish_video_to_platform(platform, local_path, video_job, creds, product)
          {platform, result}
        end)
        |> Map.new()

      File.rm(local_path)
      Logger.info("publish_video: cleaned up #{local_path}")

      tap_log_results(results, "video")
    end
  end

  defp publish_video_to_platform("youtube" = platform, local_path, video_job, creds, product) do
    opts = youtube_opts(video_job, product)

    youtube_client().upload(local_path, creds, opts)
    |> record_publish(product, video_job.draft_id, platform)
  end

  defp publish_video_to_platform("twitter" = platform, local_path, video_job, creds, product) do
    with {:ok, url} <- presign_local_for_platform(local_path, video_job, platform) do
      twitter_client().post("[Video]", creds, image_url: url)
      |> record_publish(product, video_job.draft_id, platform)
    end
  end

  defp publish_video_to_platform("facebook" = platform, local_path, video_job, creds, product) do
    with {:ok, url} <- presign_local_for_platform(local_path, video_job, platform) do
      opts = [image_url: url] ++ maybe_page_opt(product)

      facebook_client().post("[Video]", creds, opts)
      |> record_publish(product, video_job.draft_id, platform)
    end
  end

  defp publish_video_to_platform("instagram" = platform, local_path, video_job, creds, product) do
    with {:ok, url} <- presign_local_for_platform(local_path, video_job, platform) do
      opts = [image_url: url] ++ maybe_instagram_opt(product)

      facebook_client().post("[Video]", creds, [{:target, :instagram} | opts])
      |> record_publish(product, video_job.draft_id, platform)
    end
  end

  defp publish_video_to_platform("linkedin" = platform, local_path, video_job, creds, product) do
    with {:ok, url} <- presign_local_for_platform(local_path, video_job, platform) do
      opts = [image_url: url] ++ maybe_organization_opt(product)

      linkedin_client().post("[Video]", creds, opts)
      |> record_publish(product, video_job.draft_id, platform)
    end
  end

  defp publish_video_to_platform("reddit" = _platform, _local_path, _video_job, _creds, _product) do
    {:error, "Reddit does not support video uploads via API"}
  end

  defp publish_video_to_platform(platform, _local_path, _video_job, _creds, _product) do
    {:error, "Unknown or unsupported platform: #{platform}"}
  end

  # ============================================
  # Platform Status
  # ============================================

  @doc """
  Returns which platforms have valid OAuth credentials for a product.
  """
  @spec connected_platforms(Product.t()) :: [String.t()]
  def connected_platforms(%Product{publishing_targets: targets}) do
    @available_platforms
    |> Enum.filter(fn p -> targets && targets[p] && targets[p]["access_token"] end)
  end

  @doc """
  Returns detailed status of all platforms for a product.
  """
  @spec platform_status(Product.t()) :: [map()]
  def platform_status(%Product{} = product) do
    creds = build_credentials(product)

    Enum.map(@available_platforms, fn platform ->
      token_key = :"#{platform}_access_token"
      connected = !is_nil(creds[token_key])
      extra = extra_platform_info(platform, product)

      %{
        platform: platform,
        connected: connected,
        extra: extra
      }
    end)
  end

  # ============================================
  # Credential Building
  # ============================================

  defp build_credentials(%Product{publishing_targets: targets}) do
    %{
      twitter_access_token: get_in(targets, ["twitter", "access_token"]),
      youtube_access_token: get_in(targets, ["youtube", "access_token"]),
      facebook_access_token: get_in(targets, ["facebook", "access_token"]),
      instagram_access_token: get_in(targets, ["instagram", "access_token"]),
      linkedin_access_token: get_in(targets, ["linkedin", "access_token"]),
      linkedin_person_id: get_in(targets, ["linkedin", "person_id"]),
      linkedin_organization_id: get_in(targets, ["linkedin", "organization_id"]),
      reddit_access_token: get_in(targets, ["reddit", "access_token"])
    }
  end

  # ============================================
  # Helpers
  # ============================================

  # Phase 16-tail rework: now takes an explicit `draft_id` so the
  # video fan-out can thread `video_job.draft_id` through and
  # `PublishedPost` rows actually get inserted (the schema's NOT
  # NULL `draft_id` was silently rejecting every prior insert
  # attempt - reviewer's "YouTube only / others silently skip"
  # observation was masking exactly this). Both ok-clauses now
  # return the same `{:ok, %{post_id, post_url}}` shape.
  #
  # For draft-less text publishes (the MCP `cf_publish_text`
  # surface accepts a free-form text body), the PublishedPost
  # row is skipped intentionally and logged. See moduledoc for
  # the tracking-divergence rationale.
  defp record_publish({:ok, %{post_id: id, post_url: url}}, product, draft_id, platform) do
    cond do
      is_nil(product) ->
        Logger.warning(
          "PublishedPost skipped (no product context): platform=#{platform} post_id=#{id}"
        )

      is_nil(draft_id) ->
        Logger.info(
          "PublishedPost skipped (free-form text, no draft): platform=#{platform} post_id=#{id}"
        )

      true ->
        attrs = %{
          product_id: product.id,
          draft_id: draft_id,
          platform: platform,
          platform_post_id: id,
          platform_post_url: url,
          posted_at: DateTime.utc_now()
        }

        case Publishing.create_published_post(attrs) do
          {:ok, _} -> Logger.info("PublishedPost recorded: #{platform} #{id}")
          {:error, reason} -> Logger.warning("Failed to record PublishedPost: #{inspect(reason)}")
        end
    end

    {:ok, %{post_id: id, post_url: url}}
  end

  defp record_publish({:error, _} = error, _product, _draft_id, _platform), do: error

  defp download_from_r2(r2_key) when is_binary(r2_key) do
    # Phase 16-tail rework: previously this constructed a public
    # `r2.dev` URL, which only worked if the operator had flipped
    # the bucket to public read - undocumented and surprising.
    # Route through `Storage.presigned_get_url/2` so the call
    # works whether the bucket is public or private; the URL is
    # short-lived (default 15 min) and bound to the object key.
    #
    # Tests override the whole `:r2_downloader` Application env so
    # they can stand in a fake `(r2_key) -> {:ok, local_path}` fun
    # without touching R2 or the filesystem.
    fetcher =
      Application.get_env(:content_forge, :r2_downloader, &default_r2_download/1)

    fetcher.(r2_key)
  end

  defp default_r2_download(r2_key) do
    case ContentForge.Storage.presigned_get_url(r2_key) do
      {:ok, url} ->
        fetch_to_tempfile(url)

      {:error, reason} ->
        {:error, "Failed to presign R2 GET: #{inspect(reason)}"}
    end
  end

  defp fetch_to_tempfile(url) do
    tmp = Path.join(System.tmp_dir(), "cf_publish_#{:erlang.system_time(:millisecond)}.mp4")

    case Req.get(url, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: binary}} ->
        case File.write(tmp, binary) do
          :ok -> {:ok, tmp}
          {:error, reason} -> {:error, "Failed to write temp file: #{inspect(reason)}"}
        end

      {:ok, %{status: status}} ->
        {:error, "R2 download returned status #{status}"}

      {:error, reason} ->
        {:error, "R2 download failed: #{inspect(reason)}"}
    end
  end

  defp maybe_image_opt(nil), do: []
  defp maybe_image_opt(url) when is_binary(url), do: [image_url: url]

  defp maybe_page_opt(product) do
    case get_in(product.publishing_targets, ["facebook", "page_id"]) do
      nil -> []
      page_id -> [page_id: page_id]
    end
  end

  defp maybe_instagram_opt(product) do
    case get_in(product.publishing_targets, ["instagram", "account_id"]) do
      nil -> []
      account_id -> [instagram_account_id: account_id]
    end
  end

  defp maybe_organization_opt(product) do
    case get_in(product.publishing_targets, ["linkedin", "organization_id"]) do
      nil -> []
      org_id -> [target: %{type: :organization, organization_id: org_id}]
    end
  end

  defp youtube_opts(video_job, product) do
    draft = ContentForge.ContentGeneration.get_draft(video_job.draft_id)
    # Drafts have no `:title` field today; derive the YouTube
    # video title from the first heading line of `:content`,
    # falling back to a sensible default. Prevents a crash in
    # the video-publish path (was masked by the swallowing
    # rescue clauses removed in fix #4).
    title = draft && extract_title_from_content(draft.content)
    desc = draft && draft.content

    opts = [
      title: title || "Generated Video",
      description: desc || "",
      privacy: get_in(product.publishing_targets, ["youtube", "privacy"]) || "private"
    ]

    if thumbnail_key = video_job.per_step_r2_keys["avatar"] do
      [{:thumbnail_url, r2_presigned_url(thumbnail_key)} | opts]
    else
      opts
    end
  end

  defp extract_title_from_content(nil), do: nil

  defp extract_title_from_content(content) when is_binary(content) do
    content
    |> String.split("\n", trim: true)
    |> List.first()
    |> case do
      nil -> nil
      first -> first |> String.replace(~r/^#+\s*/, "") |> String.trim()
    end
    |> case do
      "" -> nil
      title -> title
    end
  end

  defp r2_presigned_url(r2_key) do
    case ContentForge.Storage.presigned_get_url(r2_key) do
      {:ok, url} ->
        url

      {:error, reason} ->
        Logger.warning("r2_presigned_url: failed to presign #{r2_key}: #{inspect(reason)}")
        nil
    end
  end

  # Phase 16-tail rework: previously this returned `file://#{path}`,
  # which gets passed to Twitter / Facebook / LinkedIn as
  # `image_url`. External APIs cannot fetch `file://` URLs (so
  # the post fails), and a publisher that tries to fetch them
  # against its own filesystem is an SSRF surface. Upload the
  # local file to R2 under a per-video distribution prefix and
  # hand the platform a short-lived presigned GET URL instead.
  #
  # Tests override the `:video_staging` Application env so the
  # staging step doesn't touch R2 or ExAws.
  defp presign_local_for_platform(local_path, video_job, platform) do
    stager =
      Application.get_env(:content_forge, :video_staging, &default_video_staging/3)

    stager.(local_path, video_job, platform)
  end

  defp default_video_staging(local_path, video_job, platform) do
    with {:ok, binary} <- File.read(local_path),
         key <- distribution_key(video_job.id, platform, local_path),
         {:ok, _url} <- ContentForge.Storage.put_object(key, binary, content_type: "video/mp4"),
         {:ok, presigned} <- ContentForge.Storage.presigned_get_url(key, expires_in: 3_600) do
      {:ok, presigned}
    else
      {:error, reason} ->
        Logger.error(
          "presign_local_for_platform: #{platform} failed for job #{video_job.id}: #{inspect(reason)}"
        )

        {:error, "video staging failed: #{inspect(reason)}"}
    end
  end

  defp distribution_key(video_job_id, platform, local_path) do
    ext = Path.extname(local_path)
    "video_distribution/#{video_job_id}/#{platform}#{ext}"
  end

  defp extra_platform_info("reddit", product) do
    %{subreddit: get_in(product.publishing_targets, ["reddit", "subreddit"])}
  end

  defp extra_platform_info("facebook", product) do
    %{page_id: get_in(product.publishing_targets, ["facebook", "page_id"])}
  end

  defp extra_platform_info("instagram", product) do
    %{account_id: get_in(product.publishing_targets, ["instagram", "account_id"])}
  end

  defp extra_platform_info("linkedin", product) do
    %{
      person_id: get_in(product.publishing_targets, ["linkedin", "person_id"]),
      organization_id: get_in(product.publishing_targets, ["linkedin", "organization_id"])
    }
  end

  defp extra_platform_info("youtube", product) do
    %{privacy: get_in(product.publishing_targets, ["youtube", "privacy"]) || "private"}
  end

  defp extra_platform_info("twitter", _product), do: %{}

  defp tap_log_results(results, type) do
    Logger.info("publish_multi: published #{map_size(results)} #{type}s across platforms")
    results
  end
end
