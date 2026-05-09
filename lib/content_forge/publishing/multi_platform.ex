defmodule ContentForge.Publishing.MultiPlatform do
  @moduledoc """
  Multi-platform publishing dispatcher.

  Takes a product's `publishing_targets` (OAuth tokens + per-platform config)
  and a content payload (text or video), then fans out to each requested
  platform. Results are tracked in `PublishedPost` rows.
  """

  require Logger

  alias ContentForge.Publishing
  alias ContentForge.Publishing.{Twitter, YouTube, Facebook, LinkedIn, Reddit}
  alias ContentForge.Products.Product

  @available_platforms ~w(twitter youtube facebook instagram linkedin reddit)

  @type post_result :: {:ok, %{platform: String.t(), post_id: String.t(), post_url: String.t()}} | {:error, String.t()}
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
  def publish_text(%Product{} = product, text, image_url \\ nil, platforms \\ @available_platforms)
      when is_binary(text) and is_list(platforms) do
    creds = build_credentials(product)

    platforms
    |> Enum.reject(&is_nil(creds[:"#{&1}_access_token"]))
    |> Enum.map(fn platform ->
      result = publish_to_platform(platform, text, image_url, creds, product)
      {platform, result}
    end)
    |> Map.new()
    |> tap_log_results("text post", length(platforms))
  end

  defp publish_to_platform("twitter" = platform, text, image_url, creds, product) do
    opts = maybe_image_opt(image_url)
    Twitter.post(text, creds, opts) |> record_publish(product, platform)
  end

  defp publish_to_platform("linkedin" = platform, text, image_url, creds, product) do
    LinkedIn.post(text, creds, maybe_image_opt(image_url) ++ maybe_organization_opt(product)) |> record_publish(product, platform)
  end

  defp publish_to_platform("reddit" = platform, text, _image_url, creds, product) do
    subreddit = get_in(product.publishing_targets, ["reddit", "subreddit"]) || "all"
    opts = [subreddit: subreddit]
    Reddit.post(text, creds, opts) |> record_publish(product, platform)
  end

  defp publish_to_platform("facebook" = platform, text, image_url, creds, product) do
    if is_nil(image_url) do
      {:error, "Facebook posts require an image URL"}
    else
      opts = [image_url: image_url] ++ maybe_page_opt(product)

      Facebook.post(text, creds, opts) |> record_publish(product, platform)
    end
  end

  defp publish_to_platform("instagram" = platform, text, image_url, creds, product) do
    if is_nil(image_url) do
      {:error, "Instagram posts require an image URL"}
    else
      base_opts = [image_url: image_url]
      opts = base_opts ++ maybe_instagram_opt(product)
      Facebook.post(text, creds, [{:target, :instagram} | opts]) |> record_publish(product, platform)
    end
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
  @spec publish_video(Publishing.VideoJob.t(), [String.t()], Product.t()) :: multi_result()
  def publish_video(%Publishing.VideoJob{} = video_job, platforms \\ @available_platforms, %Product{} = product) do
    final_key = video_job.per_step_r2_keys["final"]

    if is_nil(final_key) do
      Logger.error("publish_video: no final video key for job #{video_job.id}")
      raise "VideoJob has no final video key. Ensure encoding completed."
    end

    with {:ok, local_path} <- download_from_r2(final_key) do
      creds = build_credentials(product)

      results =
        platforms
        |> Enum.reject(&is_nil(creds[:"#{&1}_access_token"]))
        |> Enum.reject(&(&1 in video_job.published_platforms))
        |> Enum.map(fn platform ->
          result = publish_video_to_platform(platform, local_path, video_job, creds, product)
          {platform, result}
        end)
        |> Map.new()

      # Clean up temp file
      File.rm(local_path)
      Logger.info("publish_video: cleaned up #{local_path}")

      tap_log_results(results, "video", map_size(results))
    end
  end

  defp publish_video_to_platform("youtube" = platform, local_path, video_job, creds, product) do
    opts = youtube_opts(video_job, product)
    YouTube.upload(local_path, creds, opts) |> record_publish(product, platform)
  end

  defp publish_video_to_platform("twitter" = platform, local_path, _video_job, creds, _product) do
    Twitter.post("[Video]", creds, image_url: local_path_to_url(local_path))
    |> record_publish(nil, platform)
  end

  defp publish_video_to_platform("facebook" = platform, local_path, _video_job, creds, product) do
    opts = [image_url: local_path_to_url(local_path)] ++ maybe_page_opt(product)
    Facebook.post("[Video]", creds, opts) |> record_publish(product, platform)
  end

  defp publish_video_to_platform("instagram" = platform, local_path, _video_job, creds, product) do
    opts = [image_url: local_path_to_url(local_path)] ++ maybe_instagram_opt(product)
    Facebook.post("[Video]", creds, [{:target, :instagram} | opts]) |> record_publish(product, platform)
  end

  defp publish_video_to_platform("linkedin" = platform, local_path, _video_job, creds, product) do
    opts = [image_url: local_path_to_url(local_path)] ++ maybe_organization_opt(product)
    LinkedIn.post("[Video]", creds, opts) |> record_publish(product, platform)
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

  defp record_publish({:ok, %{post_id: id, post_url: url}}, product, platform)
      when not is_nil(product) do
    attrs = %{
      product_id: product.id,
      platform: platform,
      platform_post_id: id,
      platform_post_url: url,
      posted_at: DateTime.utc_now()
    }

    case Publishing.create_published_post(attrs) do
      {:ok, _} -> Logger.info("PublishedPost recorded: #{platform} #{id}")
      {:error, reason} -> Logger.warning("Failed to record PublishedPost: #{inspect(reason)}")
    end

    {:ok, %{post_id: id, post_url: url}}
  end

  defp record_publish({:ok, %{post_id: _id, post_url: _}}, _product, _platform), do: {:ok, :recorded}

  defp record_publish({:error, _} = error, _product, _platform), do: error

  defp download_from_r2(r2_key) when is_binary(r2_key) do
    bucket = Application.get_env(:content_forge, :r2)[:bucket]

    if is_nil(bucket) do
      {:error, "R2 not configured"}
    else
      url = "https://#{bucket}.r2.dev/#{r2_key}"
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
    title = draft && draft.title
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

  defp r2_presigned_url(r2_key) do
    bucket = Application.get_env(:content_forge, :r2)[:bucket]
    "https://#{bucket}.r2.dev/#{r2_key}"
  end

  defp local_path_to_url(path) do
    # For local files, just return the path -- the platform connector will fetch it
    "file://#{path}"
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

  defp tap_log_results(results, type, count) do
    Logger.info("publish_multi: published #{count} #{type}s across platforms")
    results
  end
end