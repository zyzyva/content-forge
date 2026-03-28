defmodule ContentForge.Publishing.Facebook do
  @moduledoc """
  Facebook/Instagram connector using Meta Graph API.
  Posts text + image to Facebook page or Instagram business account.
  """

  require Logger

  @base_url "https://graph.facebook.com/v18.0"
  @max_retries 3
  @retry_delay 5000

  @type post_result :: {:ok, %{post_id: String.t(), post_url: String.t()}} | {:error, String.t()}

  @doc """
  Post to Facebook page or Instagram.

  ## Options
    - `:image_url` - URL of image to attach (required)
    - `:target` - :facebook_page or :instagram (default: :facebook_page)
    - `:page_id` - Facebook page ID (required for facebook_page target)
    - `:instagram_account_id` - Instagram business account ID (required for instagram target)
    - `:retry` - Number of retries (default: 3)
  """
  @spec post(binary(), map(), keyword()) :: post_result()
  def post(text, %{facebook_access_token: _token} = credentials, opts \\ []) do
    retry_count = Keyword.get(opts, :retry, @max_retries)
    target = Keyword.get(opts, :target, :facebook_page)
    do_post(text, credentials, target, opts, retry_count)
  end

  defp do_post(_text, _credentials, _target, _opts, 0) do
    Logger.error("Facebook: All retries exhausted")
    {:error, "Failed to post after multiple attempts"}
  end

  defp do_post(text, credentials, target, opts, attempts_left) do
    image_url = Keyword.get(opts, :image_url)

    if is_nil(image_url) do
      {:error, "Image URL is required for Facebook/Instagram posts"}
    else
      case perform_post(text, credentials, target, image_url, opts) do
        {:ok, response} ->
          {:ok, response}

        {:error, reason} ->
          Logger.warning(
            "Facebook: Post failed, attempts left: #{attempts_left}, error: #{inspect(reason)}"
          )

          Process.sleep(@retry_delay)
          do_post(text, credentials, target, opts, attempts_left - 1)
      end
    end
  end

  defp perform_post(text, credentials, :facebook_page, image_url, opts) do
    page_id = Keyword.fetch!(opts, :page_id)

    # First upload the photo
    case upload_photo(credentials, page_id, image_url, text) do
      {:ok, photo_id} ->
        # Create the post using the photo
        path = "/#{page_id}/feed"
        body = %{message: text, attached_media: "[{\"media_fbid\": \"#{photo_id}\"}]"}

        case facebook_request(:post, path, credentials, body) do
          {:ok, %{"id" => post_id}} ->
            post_url = "https://www.facebook.com/#{page_id}/posts/#{post_id}"
            Logger.info("Facebook: Posted to page #{page_id} #{post_id}")
            {:ok, %{post_id: post_id, post_url: post_url}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp perform_post(text, credentials, :instagram, image_url, opts) do
    instagram_account_id = Keyword.fetch!(opts, :instagram_account_id)

    # First upload the media container
    case create_media_container(credentials, instagram_account_id, image_url, text) do
      {:ok, container_id} ->
        # Then publish the media
        case publish_media(credentials, instagram_account_id, container_id) do
          {:ok, media_id} ->
            post_url = "https://www.instagram.com/p/#{media_id}/"
            Logger.info("Instagram: Posted to account #{instagram_account_id} #{media_id}")
            {:ok, %{post_id: media_id, post_url: post_url}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upload_photo(credentials, page_id, image_url, caption) do
    path = "/#{page_id}/photos"

    body = %{
      url: image_url,
      caption: caption,
      published: false
    }

    case facebook_request(:post, path, credentials, body) do
      {:ok, %{"id" => photo_id}} ->
        {:ok, photo_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_media_container(credentials, instagram_account_id, image_url, caption) do
    path = "/#{instagram_account_id}/media"

    body = %{
      image_url: image_url,
      caption: caption
    }

    case facebook_request(:post, path, credentials, body) do
      {:ok, %{"id" => container_id}} ->
        {:ok, container_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp publish_media(credentials, instagram_account_id, container_id) do
    path = "/#{instagram_account_id}/media_publish"

    body = %{creation_id: container_id}

    case facebook_request(:post, path, credentials, body) do
      {:ok, %{"id" => media_id}} ->
        {:ok, media_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp facebook_request(method, path, credentials, body) do
    url = @base_url <> path

    # Add access token to all requests
    body_with_token = Map.put(body, :access_token, credentials.facebook_access_token)

    headers = [{"Content-Type", "application/json"}]

    case method do
      :post ->
        case Req.post(url, json: body_with_token, headers: headers) do
          {:ok, %{status: status, body: body}} when status in 200..299 ->
            {:ok, body}

          {:ok, %{status: status, body: %{"error" => error}}} when status >= 400 ->
            Logger.error("Facebook API error: #{inspect(error)}")
            {:error, error}

          {:ok, %{status: status, body: body}} when status >= 400 ->
            Logger.error("Facebook API error: #{status} - #{inspect(body)}")
            {:error, body}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end
end
