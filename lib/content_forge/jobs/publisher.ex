defmodule ContentForge.Jobs.Publisher do
  @moduledoc """
  Oban job for publishing approved drafts to social platforms.
  Picks optimal posting windows based on historical engagement data.
  """

  use Oban.Worker, max_attempts: 3

  alias ContentForge.{ContentGeneration, Products, Publishing}
  alias ContentForge.ContentGeneration.Draft
  alias ContentForge.ContentGeneration.DraftAsset
  alias ContentForge.ProductAssets.RenditionResolver
  alias ContentForge.Repo

  require Logger

  @missing_image_reason "Social post missing required AI-generated image (Stage 3.5)"
  @carousel_platforms ~w(instagram facebook)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"product_id" => product_id, "platform" => platform}}) do
    Logger.info("Publisher: Starting for product #{product_id}, platform #{platform}")

    # Get product with publishing targets
    case Products.get_product(product_id) do
      nil ->
        Logger.error("Publisher: Product not found #{product_id}")
        {:cancel, "Product not found"}

      product ->
        # Get optimal posting window
        optimal_windows = Publishing.get_optimal_posting_windows(product_id, platform)

        # Find next approved draft for this platform
        case find_next_draft(product_id, platform) do
          nil ->
            Logger.info(
              "Publisher: No approved drafts for product #{product_id}, platform #{platform}"
            )

            :ok

          draft ->
            case enforce_image_required(draft) do
              {:blocked, reason} ->
                {:cancel, reason}

              {:ok, draft} ->
                publish_to_platform(draft, product, platform, optimal_windows)
            end
        end
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"draft_id" => draft_id}}) do
    Logger.info("Publisher: Starting for draft #{draft_id}")

    case ContentForge.ContentGeneration.get_draft(draft_id) do
      nil ->
        {:cancel, "Draft not found"}

      draft ->
        case Products.get_product(draft.product_id) do
          nil ->
            Logger.error("Publisher: Product not found for draft #{draft_id}")
            {:cancel, "Product not found"}

          product ->
            do_publish(draft, product)
        end
    end
  end

  defp publish_to_platform(draft, product, platform, optimal_windows) do
    case resolve_post_assets(draft, platform) do
      {:ok, resolution} ->
        publish_with_resolution(draft, product, platform, optimal_windows, resolution)

      {:blocked, reason} ->
        {:ok, _} = ContentGeneration.mark_draft_blocked(draft)
        {:cancel, reason}

      {:error, _} = err ->
        err
    end
  end

  defp publish_with_resolution(draft, product, platform, optimal_windows, resolution) do
    case get_credentials(product, platform) do
      nil ->
        Logger.error("Publisher: No credentials for platform #{platform}")
        {:cancel, "No credentials for platform"}

      credentials ->
        opts = build_post_opts(draft, optimal_windows, product, resolution)
        platform_module = get_platform_module(platform)

        case platform_module.post(draft.content, credentials, opts) do
          {:ok, %{post_id: post_id, post_url: post_url}} ->
            Publishing.create_published_post(%{
              product_id: draft.product_id,
              draft_id: draft.id,
              platform: platform,
              platform_post_id: post_id,
              platform_post_url: post_url,
              posted_at: DateTime.utc_now()
            })

            Draft.changeset(draft, %{status: "published"}) |> Repo.update!()

            Logger.info("Publisher: Published draft #{draft.id} to #{platform}")
            :ok

          {:error, reason} ->
            Logger.error("Publisher: Failed to publish to #{platform}: #{reason}")
            {:error, reason}
        end
    end
  end

  defp do_publish(draft, product) do
    case enforce_image_required(draft) do
      {:blocked, reason} -> {:cancel, reason}
      {:ok, draft} -> do_publish_approved(draft, product)
    end
  end

  defp do_publish_approved(draft, product) do
    case resolve_post_assets(draft, draft.platform) do
      {:ok, resolution} ->
        do_publish_with_resolution(draft, product, resolution)

      {:blocked, reason} ->
        {:ok, _} = ContentGeneration.mark_draft_blocked(draft)
        {:cancel, reason}

      {:error, _} = err ->
        err
    end
  end

  defp do_publish_with_resolution(draft, product, resolution) do
    case get_credentials(product, draft.platform) do
      nil ->
        {:cancel, "No credentials for platform"}

      credentials ->
        optimal_windows =
          Publishing.get_optimal_posting_windows(draft.product_id, draft.platform)

        opts = build_post_opts(draft, optimal_windows, product, resolution)
        platform_module = get_platform_module(draft.platform)

        case platform_module.post(draft.content, credentials, opts) do
          {:ok, %{post_id: post_id, post_url: post_url}} ->
            Publishing.create_published_post(%{
              product_id: draft.product_id,
              draft_id: draft.id,
              platform: draft.platform,
              platform_post_id: post_id,
              platform_post_url: post_url,
              posted_at: DateTime.utc_now()
            })

            Draft.changeset(draft, %{status: "published"}) |> Repo.update!()

            Logger.info("Publisher: Published draft #{draft.id} to #{draft.platform}")
            :ok

          {:error, reason} ->
            Logger.error("Publisher: Failed to publish: #{reason}")
            {:error, reason}
        end
    end
  end

  defp enforce_image_required(%Draft{content_type: "post", image_url: nil} = draft) do
    Logger.warning("Publisher: publish blocked: missing image for draft #{draft.id}")
    {:ok, _blocked} = ContentGeneration.mark_draft_blocked(draft)
    {:blocked, @missing_image_reason}
  end

  defp enforce_image_required(%Draft{content_type: "post", image_url: ""} = draft) do
    Logger.warning("Publisher: publish blocked: missing image for draft #{draft.id}")
    {:ok, _blocked} = ContentGeneration.mark_draft_blocked(draft)
    {:blocked, @missing_image_reason}
  end

  defp enforce_image_required(draft), do: {:ok, draft}

  defp find_next_draft(product_id, platform) do
    import Ecto.Query

    query =
      from d in Draft,
        where: d.product_id == ^product_id,
        where: d.platform == ^platform,
        where: d.status == "approved",
        order_by: [asc: d.inserted_at],
        limit: 1

    ContentForge.Repo.one(query)
  end

  defp get_credentials(product, "twitter") do
    publishing_config = product.publishing_targets || %{}
    twitter_config = publishing_config["twitter"] || %{}

    if twitter_config["enabled"] && twitter_config["access_token"] && twitter_config["api_key"] do
      %{
        twitter_access_token: twitter_config["access_token"],
        twitter_api_key: twitter_config["api_key"]
      }
    else
      nil
    end
  end

  defp get_credentials(product, "linkedin") do
    publishing_config = product.publishing_targets || %{}
    linkedin_config = publishing_config["linkedin"] || %{}

    if linkedin_config["enabled"] && linkedin_config["access_token"] &&
         linkedin_config["person_id"] do
      %{
        linkedin_access_token: linkedin_config["access_token"],
        linkedin_person_id: linkedin_config["person_id"]
      }
    else
      nil
    end
  end

  defp get_credentials(product, "reddit") do
    publishing_config = product.publishing_targets || %{}
    reddit_config = publishing_config["reddit"] || %{}

    if reddit_config["enabled"] && reddit_config["access_token"] && reddit_config["subreddit"] do
      %{
        reddit_access_token: reddit_config["access_token"]
      }
    else
      nil
    end
  end

  defp get_credentials(product, "facebook") do
    publishing_config = product.publishing_targets || %{}
    facebook_config = publishing_config["facebook"] || %{}

    if facebook_config["enabled"] && facebook_config["access_token"] && facebook_config["page_id"] do
      %{
        facebook_access_token: facebook_config["access_token"],
        facebook_page_id: facebook_config["page_id"]
      }
    else
      nil
    end
  end

  defp get_credentials(product, "instagram") do
    publishing_config = product.publishing_targets || %{}
    instagram_config = publishing_config["instagram"] || %{}

    if instagram_config["enabled"] && instagram_config["access_token"] &&
         instagram_config["account_id"] do
      %{
        facebook_access_token: instagram_config["access_token"],
        instagram_account_id: instagram_config["account_id"]
      }
    else
      nil
    end
  end

  defp get_credentials(_product, _platform), do: nil

  defp get_platform_module("twitter"), do: ContentForge.Publishing.Twitter
  defp get_platform_module("linkedin"), do: ContentForge.Publishing.LinkedIn
  defp get_platform_module("reddit"), do: ContentForge.Publishing.Reddit
  defp get_platform_module("facebook"), do: ContentForge.Publishing.Facebook
  defp get_platform_module("instagram"), do: ContentForge.Publishing.Facebook

  @doc """
  Builds the keyword list of options passed to the platform client's
  `post/3` function. `resolution` carries the URLs resolved from
  attached draft_assets (or the legacy single-URL wrapper); this is
  where the primary image and the optional carousel list are wired in.

  Made public so `publisher_rendition_test.exs` can drive it directly
  without having to re-implement the carousel + platform-specific
  option wiring inline.
  """
  def build_post_opts(draft, _optimal_windows, product, resolution) do
    opts =
      []
      |> put_primary_image(resolution)
      |> put_carousel(draft.platform, resolution)

    put_platform_opts(opts, draft.platform, product)
  end

  defp put_primary_image(opts, %{primary_url: url}) when is_binary(url),
    do: Keyword.put(opts, :image_url, url)

  defp put_primary_image(opts, _), do: opts

  defp put_carousel(opts, platform, %{gallery_urls: [_ | _] = urls})
       when platform in @carousel_platforms do
    Keyword.put(opts, :carousel, urls)
  end

  defp put_carousel(opts, _platform, _resolution), do: opts

  defp put_platform_opts(opts, "linkedin", product) do
    publishing_config = product.publishing_targets || %{}
    linkedin_config = publishing_config["linkedin"] || %{}
    target_type = linkedin_config["target_type"] || "profile"

    if target_type == "organization" && linkedin_config["organization_id"] do
      Keyword.put(opts, :target, %{
        type: :organization,
        organization_id: linkedin_config["organization_id"]
      })
    else
      Keyword.put(opts, :target, :profile)
    end
  end

  defp put_platform_opts(opts, "reddit", product) do
    reddit_config = (product.publishing_targets || %{})["reddit"] || %{}
    Keyword.put(opts, :subreddit, reddit_config["subreddit"] || "general")
  end

  defp put_platform_opts(opts, "facebook", product) do
    facebook_config = (product.publishing_targets || %{})["facebook"] || %{}

    opts
    |> Keyword.put(:page_id, facebook_config["page_id"])
    |> Keyword.put(:target, :facebook_page)
  end

  defp put_platform_opts(opts, "instagram", product) do
    instagram_config = (product.publishing_targets || %{})["instagram"] || %{}

    opts
    |> Keyword.put(:instagram_account_id, instagram_config["account_id"])
    |> Keyword.put(:target, :instagram)
  end

  defp put_platform_opts(opts, _platform, _product), do: opts

  # --- asset resolution -----------------------------------------------------

  # Returns one of:
  #   {:ok, %{primary_url, gallery_urls}}
  #   {:blocked, reason_string}  - mark draft blocked, {:cancel, reason}
  #   {:error, reason_tuple}     - propagate for Oban retry
  #
  # Legacy drafts (no attached draft_assets) collapse to
  # `{:ok, %{primary_url: draft.image_url, gallery_urls: []}}` so the
  # build_post_opts path is uniform.
  defp resolve_post_assets(%Draft{} = draft, platform) do
    case load_attachments(draft.id) do
      [] -> {:ok, %{primary_url: draft.image_url, gallery_urls: []}}
      attachments -> resolve_attachments(attachments, draft, platform)
    end
  end

  defp load_attachments(draft_id) do
    import Ecto.Query

    from(da in DraftAsset,
      where: da.draft_id == ^draft_id,
      order_by: [asc: da.inserted_at],
      preload: :asset
    )
    |> Repo.all()
  end

  defp resolve_attachments(attachments, draft, platform) do
    {featured, gallery} = split_by_role(attachments)

    with {:ok, primary_url} <- resolve_primary(featured, draft, platform),
         {:ok, gallery_urls} <- resolve_gallery(gallery, platform) do
      {:ok, %{primary_url: primary_url, gallery_urls: gallery_urls}}
    end
  end

  defp split_by_role(attachments) do
    {featured, rest} = Enum.split_with(attachments, &(&1.role == "featured"))

    # Fall back to the first attachment as featured when no role-tagged row
    # exists. This matches 13.4b's behavior (which always tags "featured")
    # but keeps pre-role-tagging drafts from breaking.
    case featured do
      [first | _] -> {first, rest ++ Enum.drop(featured, 1)}
      [] -> take_first(attachments)
    end
  end

  defp take_first([]), do: {nil, []}
  defp take_first([first | rest]), do: {first, rest}

  defp resolve_primary(nil, draft, _platform), do: {:ok, draft.image_url}

  defp resolve_primary(%DraftAsset{asset: asset}, draft, platform) do
    asset
    |> RenditionResolver.resolve(platform)
    |> interpret_resolver_result(draft, platform)
  end

  defp resolve_gallery([], _platform), do: {:ok, []}

  defp resolve_gallery(attachments, platform) do
    attachments
    |> Enum.reduce_while({:ok, []}, fn %DraftAsset{asset: asset}, {:ok, acc} ->
      case RenditionResolver.resolve(asset, platform) do
        {:ok, url} when is_binary(url) -> {:cont, {:ok, acc ++ [url]}}
        # Async/video paths contribute nothing this slice; skip cleanly.
        {:ok, {:async, _}} -> {:cont, {:ok, acc}}
        {:error, _} = err -> {:halt, interpret_gallery_error(err)}
      end
    end)
  end

  defp interpret_resolver_result({:ok, url}, _draft, _platform) when is_binary(url),
    do: {:ok, url}

  defp interpret_resolver_result({:ok, {:async, _}}, draft, _platform),
    do: {:ok, draft.image_url}

  defp interpret_resolver_result({:error, :not_configured}, draft, _platform) do
    Logger.warning(
      "Publisher: rendition unavailable for draft #{draft.id}: media forge not configured"
    )

    {:blocked, "rendition unavailable: media forge not configured"}
  end

  defp interpret_resolver_result({:error, {:transient, _, _} = reason}, draft, _platform) do
    Logger.warning(
      "Publisher: transient rendition error for draft #{draft.id}; Oban will retry (#{inspect(reason)})"
    )

    {:error, reason}
  end

  defp interpret_resolver_result({:error, {:http_error, status, body}}, draft, _platform) do
    Logger.error(
      "Publisher: permanent rendition error for draft #{draft.id}: HTTP #{status} #{inspect(body)}"
    )

    {:blocked, "rendition failed: HTTP #{status}"}
  end

  defp interpret_resolver_result({:error, {:unexpected_status, status, _}}, draft, _platform) do
    Logger.error(
      "Publisher: rendition returned unexpected status #{status} for draft #{draft.id}"
    )

    {:blocked, "rendition failed: unexpected HTTP #{status}"}
  end

  defp interpret_resolver_result({:error, {:unexpected_body, body}}, draft, _platform) do
    Logger.error(
      "Publisher: rendition returned unexpected body for draft #{draft.id}: #{inspect(body)}"
    )

    {:blocked, "rendition failed: unexpected response body"}
  end

  defp interpret_resolver_result({:error, reason}, draft, _platform) do
    Logger.error("Publisher: rendition error for draft #{draft.id}: #{inspect(reason)}")
    {:error, reason}
  end

  defp interpret_gallery_error({:error, {:transient, _, _} = reason}), do: {:error, reason}

  defp interpret_gallery_error({:error, :not_configured}),
    do: {:blocked, "rendition unavailable: media forge not configured"}

  defp interpret_gallery_error({:error, {:http_error, status, _}}),
    do: {:blocked, "rendition failed: HTTP #{status}"}

  defp interpret_gallery_error({:error, {:unexpected_status, status, _}}),
    do: {:blocked, "rendition failed: unexpected HTTP #{status}"}

  defp interpret_gallery_error({:error, {:unexpected_body, _}}),
    do: {:blocked, "rendition failed: unexpected response body"}

  defp interpret_gallery_error({:error, reason}), do: {:error, reason}
end
