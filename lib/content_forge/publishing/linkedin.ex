defmodule ContentForge.Publishing.LinkedIn do
  @moduledoc """
  LinkedIn connector using LinkedIn Marketing API.
  Posts text + image to personal profile or company page.
  """

  require Logger

  @base_url "https://api.linkedin.com/v2"
  @max_retries 3
  @retry_delay 5000

  @type post_result :: {:ok, %{post_id: String.t(), post_url: String.t()}} | {:error, String.t()}

  @doc """
  Post to LinkedIn profile or company page.

  ## Options
    - `:image_url` - URL of image to attach (optional)
    - `:target` - :profile (default) or %{type: :organization, organization_id: "..."}
    - `:retry` - Number of retries (default: 3)
  """
  @spec post(binary(), map(), keyword()) :: post_result()
  def post(text, %{linkedin_access_token: _token} = credentials, opts \\ []) do
    retry_count = Keyword.get(opts, :retry, @max_retries)
    target = Keyword.get(opts, :target, :profile)
    do_post(text, credentials, target, opts, retry_count)
  end

  defp do_post(_text, _credentials, _target, _opts, 0) do
    Logger.error("LinkedIn: All retries exhausted")
    {:error, "Failed to post after multiple attempts"}
  end

  defp do_post(text, credentials, target, opts, attempts_left) do
    image_url = Keyword.get(opts, :image_url)

    case perform_post(text, credentials, target, image_url) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        Logger.warning(
          "LinkedIn: Post failed, attempts left: #{attempts_left}, error: #{inspect(reason)}"
        )

        Process.sleep(@retry_delay)
        do_post(text, credentials, target, opts, attempts_left - 1)
    end
  end

  defp perform_post(text, credentials, :profile, nil) do
    # Text-only post to profile
    urn = "urn:li:person:#{credentials.linkedin_person_id}"
    body = build_profile_post(text, urn)

    case linkedin_request(:post, "/ugcPosts", credentials, body) do
      {:ok, %{"id" => post_id}} ->
        post_url = "https://www.linkedin.com/feed/update/#{post_id}"
        Logger.info("LinkedIn: Posted to profile #{post_id}")
        {:ok, %{post_id: post_id, post_url: post_url}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp perform_post(text, credentials, :profile, image_url) do
    # Post with image to profile
    urn = "urn:li:person:#{credentials.linkedin_person_id}"

    case upload_media(image_url, credentials) do
      {:ok, asset_urn} ->
        body = build_profile_post_with_media(text, urn, asset_urn)

        case linkedin_request(:post, "/ugcPosts", credentials, body) do
          {:ok, %{"id" => post_id}} ->
            post_url = "https://www.linkedin.com/feed/update/#{post_id}"
            Logger.info("LinkedIn: Posted to profile with media #{post_id}")
            {:ok, %{post_id: post_id, post_url: post_url}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, "Media upload failed: #{reason}"}
    end
  end

  defp perform_post(text, credentials, %{type: :organization, organization_id: org_id}, nil) do
    # Text-only post to company page
    urn = "urn:li:organization:#{org_id}"
    body = build_organization_post(text, urn)

    case linkedin_request(:post, "/ugcPosts", credentials, body) do
      {:ok, %{"id" => post_id}} ->
        post_url = "https://www.linkedin.com/feed/update/#{post_id}"
        Logger.info("LinkedIn: Posted to organization #{org_id} #{post_id}")
        {:ok, %{post_id: post_id, post_url: post_url}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp perform_post(text, credentials, %{type: :organization, organization_id: org_id}, image_url) do
    # Post with image to company page
    urn = "urn:li:organization:#{org_id}"

    case upload_media(image_url, credentials) do
      {:ok, asset_urn} ->
        body = build_organization_post_with_media(text, urn, asset_urn)

        case linkedin_request(:post, "/ugcPosts", credentials, body) do
          {:ok, %{"id" => post_id}} ->
            post_url = "https://www.linkedin.com/feed/update/#{post_id}"
            Logger.info("LinkedIn: Posted to organization #{org_id} with media #{post_id}")
            {:ok, %{post_id: post_id, post_url: post_url}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, "Media upload failed: #{reason}"}
    end
  end

  defp build_profile_post(text, author_urn) do
    %{
      "author" => author_urn,
      "lifecycleState" => "PUBLISHED",
      "specificContent" => %{
        "com.linkedin.ugc.ShareContent" => %{
          "shareCommentary" => %{
            "text" => text
          },
          "shareMediaCategory" => "NONE"
        }
      },
      "visibility" => %{
        "com.linkedin.ugc.MemberNetworkVisibility" => "PUBLIC"
      }
    }
  end

  defp build_profile_post_with_media(text, author_urn, asset_urn) do
    %{
      "author" => author_urn,
      "lifecycleState" => "PUBLISHED",
      "specificContent" => %{
        "com.linkedin.ugc.ShareContent" => %{
          "shareCommentary" => %{
            "text" => text
          },
          "shareMediaCategory" => "IMAGE",
          "media" => [
            %{
              "status" => "READY",
              "media" => asset_urn
            }
          ]
        }
      },
      "visibility" => %{
        "com.linkedin.ugc.MemberNetworkVisibility" => "PUBLIC"
      }
    }
  end

  defp build_organization_post(text, author_urn) do
    %{
      "author" => author_urn,
      "lifecycleState" => "PUBLISHED",
      "specificContent" => %{
        "com.linkedin.ugc.ShareContent" => %{
          "shareCommentary" => %{
            "text" => text
          },
          "shareMediaCategory" => "NONE"
        }
      },
      "visibility" => %{
        "com.linkedin.ugc.MemberNetworkVisibility" => "PUBLIC"
      }
    }
  end

  defp build_organization_post_with_media(text, author_urn, asset_urn) do
    %{
      "author" => author_urn,
      "lifecycleState" => "PUBLISHED",
      "specificContent" => %{
        "com.linkedin.ugc.ShareContent" => %{
          "shareCommentary" => %{
            "text" => text
          },
          "shareMediaCategory" => "IMAGE",
          "media" => [
            %{
              "status" => "READY",
              "media" => asset_urn
            }
          ]
        }
      },
      "visibility" => %{
        "com.linkedin.ugc.MemberNetworkVisibility" => "PUBLIC"
      }
    }
  end

  defp upload_media(media_url, credentials) do
    # Register upload first
    register_body = %{
      "registerUploadRequest" => %{
        "recipes" => ["urn:li:digitalmediaRecipe:feedshare-image"],
        "owner" => "urn:li:person:#{credentials.linkedin_person_id}",
        "serviceRelationships" => [
          %{
            "relationshipType" => "OWNER",
            "identifier" => "urn:li:userGeneratedContent"
          }
        ]
      }
    }

    case linkedin_request(:post, "/assets", credentials, register_body) do
      {:ok,
       %{
         "value" => %{
           "asset" => asset_urn,
           "uploadMechanism" => %{
             "com.linkedin.digitalmediaUploadingMediaUploadHttpMessage" => %{
               "uploadUrl" => upload_url
             }
           }
         }
       }} ->
        # Fetch and upload the image
        case Req.get(media_url) do
          {:ok, %{status: 200, body: binary}} ->
            content_type = detect_content_type(binary)

            upload_headers = [
              {"Authorization", "Bearer #{credentials.linkedin_access_token}"},
              {"Content-Type", content_type}
            ]

            case Req.put(upload_url, body: binary, headers: upload_headers) do
              {:ok, %{status: status}} when status in 200..299 ->
                {:ok, asset_urn}

              {:ok, %{status: status, body: body}} ->
                {:error, "Upload failed with status #{status}: #{inspect(body)}"}

              {:error, reason} ->
                {:error, reason}
            end

          {:error, reason} ->
            {:error, "Failed to fetch image: #{reason}"}
        end

      {:error, reason} ->
        {:error, "Failed to register upload: #{reason}"}
    end
  end

  @doc """
  Fetch engagement metrics for a published LinkedIn post.
  post_id should be the ugcPost URN numeric portion or full URN.
  """
  @spec fetch_metrics(String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def fetch_metrics(post_id, %{linkedin_access_token: token} = _credentials) do
    urn = if String.starts_with?(post_id, "urn:"), do: post_id, else: "urn:li:ugcPost:#{post_id}"
    url = "#{@base_url}/shareStatistics?q=ugcPost&ugcPost=#{URI.encode(urn)}"

    headers = [
      {"Authorization", "Bearer #{token}"},
      {"X-Restli-Protocol-Version", "2.0.0"}
    ]

    case Req.get(url, headers: headers) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        stats = get_in(body, ["elements", Access.at(0), "totalShareStatistics"]) || %{}

        {:ok,
         %{
           "likes" => stats["likeCount"] || 0,
           "comments" => stats["commentCount"] || 0,
           "shares" => stats["shareCount"] || 0,
           "impressions" => stats["impressionCount"] || 0
         }}

      {:ok, %{status: status, body: body}} ->
        Logger.error("LinkedIn metrics error #{status}: #{inspect(body)}")
        {:error, "API error #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp linkedin_request(method, path, credentials, body) do
    url = @base_url <> path

    headers = [
      {"Authorization", "Bearer #{credentials.linkedin_access_token}"},
      {"Content-Type", "application/json"},
      {"X-Restli-Protocol-Version", "2.0.0"}
    ]

    case method do
      :post ->
        case Req.post(url, json: body, headers: headers) do
          {:ok, %{status: status, body: body}} when status in 200..299 ->
            {:ok, body}

          {:ok, %{status: status, body: body}} when status >= 400 ->
            Logger.error("LinkedIn API error: #{status} - #{inspect(body)}")
            {:error, body}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp detect_content_type(binary) do
    case binary do
      <<0x89, 0x50, 0x4E, 0x47, _::binary>> -> "image/png"
      <<0xFF, 0xD8, 0xFF, _::binary>> -> "image/jpeg"
      <<0x47, 0x49, 0x46, 0x38, _::binary>> -> "image/gif"
      <<0x57, 0x45, 0x42, 0x50, _::binary>> -> "image/webp"
      _ -> "image/jpeg"
    end
  end
end
