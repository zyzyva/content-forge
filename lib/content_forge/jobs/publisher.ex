defmodule ContentForge.Jobs.Publisher do
  @moduledoc """
  Oban job for publishing approved drafts to social platforms.
  Picks optimal posting windows based on historical engagement data.
  """

  use Oban.Worker, max_attempts: 3

  alias ContentForge.{Products, Publishing}
  alias ContentForge.ContentGeneration.Draft

  require Logger

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
            # Get credentials for the platform
            case get_credentials(product, platform) do
              nil ->
                Logger.error("Publisher: No credentials for platform #{platform}")
                {:cancel, "No credentials for platform"}

              credentials ->
                # Post to the platform
                opts = build_post_opts(draft, optimal_windows, product)
                platform_module = get_platform_module(platform)

                case platform_module.post(draft.content, credentials, opts) do
                  {:ok, %{post_id: post_id, post_url: post_url}} ->
                    # Record the published post
                    Publishing.create_published_post(%{
                      product_id: product_id,
                      draft_id: draft.id,
                      platform: platform,
                      platform_post_id: post_id,
                      platform_post_url: post_url,
                      posted_at: DateTime.utc_now()
                    })

                    # Update draft status
                    Draft.changeset(draft, %{status: "published"}) |> ContentForge.Repo.update!()

                    Logger.info("Publisher: Published draft #{draft.id} to #{platform}")
                    :ok

                  {:error, reason} ->
                    Logger.error("Publisher: Failed to publish to #{platform}: #{reason}")
                    {:error, reason}
                end
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

  defp do_publish(draft, product) do
    case get_credentials(product, draft.platform) do
      nil ->
        {:cancel, "No credentials for platform"}

      credentials ->
        optimal_windows =
          Publishing.get_optimal_posting_windows(draft.product_id, draft.platform)

        opts = build_post_opts(draft, optimal_windows, product)
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

            Draft.changeset(draft, %{status: "published"}) |> ContentForge.Repo.update!()

            Logger.info("Publisher: Published draft #{draft.id} to #{draft.platform}")
            :ok

          {:error, reason} ->
            Logger.error("Publisher: Failed to publish: #{reason}")
            {:error, reason}
        end
    end
  end

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

  defp build_post_opts(draft, _optimal_windows, product) do
    opts = []

    # Add image URL if available
    opts =
      if draft.image_url do
        Keyword.put(opts, :image_url, draft.image_url)
      else
        opts
      end

    # Add platform-specific options
    opts =
      case draft.platform do
        "linkedin" ->
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

        "reddit" ->
          publishing_config = product.publishing_targets || %{}
          reddit_config = publishing_config["reddit"] || %{}
          Keyword.put(opts, :subreddit, reddit_config["subreddit"] || "general")

        "facebook" ->
          publishing_config = product.publishing_targets || %{}
          facebook_config = publishing_config["facebook"] || %{}

          opts
          |> Keyword.put(:page_id, facebook_config["page_id"])
          |> Keyword.put(:target, :facebook_page)

        "instagram" ->
          publishing_config = product.publishing_targets || %{}
          instagram_config = publishing_config["instagram"] || %{}

          opts
          |> Keyword.put(:instagram_account_id, instagram_config["account_id"])
          |> Keyword.put(:target, :instagram)

        _ ->
          opts
      end

    opts
  end
end
