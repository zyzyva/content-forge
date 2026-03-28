defmodule ContentForge.Publishing.Twitter do
  @moduledoc """
  Twitter/X connector using Twitter API v2.
  Posts text (up to 280 chars) with optional image attachment.
  """

  require Logger

  @base_url "https://api.twitter.com/2"
  @max_retries 3
  @retry_delay 5000

  @type post_result :: {:ok, %{post_id: String.t(), post_url: String.t()}} | {:error, String.t()}

  @doc """
  Post a tweet with text and optional image.

  ## Options
    - `:image_url` - URL of image to attach (optional)
    - `:retry` - Number of retries (default: 3)
  """
  @spec post(binary(), map(), keyword()) :: post_result()
  def post(text, %{twitter_access_token: _token, twitter_api_key: _key} = credentials, opts \\ []) do
    retry_count = Keyword.get(opts, :retry, @max_retries)
    do_post(text, credentials, opts, retry_count)
  end

  defp do_post(_text, _credentials, _opts, 0) do
    Logger.error("Twitter: All retries exhausted")
    {:error, "Failed to post after multiple attempts"}
  end

  defp do_post(text, credentials, opts, attempts_left) do
    image_url = Keyword.get(opts, :image_url)

    case perform_post(text, credentials, image_url) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        Logger.warning(
          "Twitter: Post failed, attempts left: #{attempts_left}, error: #{inspect(reason)}"
        )

        Process.sleep(@retry_delay)
        do_post(text, credentials, opts, attempts_left - 1)
    end
  end

  defp perform_post(text, credentials, nil) do
    # Text-only tweet
    body = %{text: String.slice(text, 0, 280)}

    case twitter_request(:post, "/tweets", credentials, body) do
      {:ok, %{"data" => %{"id" => tweet_id}}} ->
        post_url = "https://twitter.com/i/status/#{tweet_id}"
        Logger.info("Twitter: Posted tweet #{tweet_id}")
        {:ok, %{post_id: tweet_id, post_url: post_url}}

      {:ok, error} ->
        {:error, error}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp perform_post(text, credentials, image_url) do
    # First upload the media
    case upload_media(image_url, credentials) do
      {:ok, media_id} ->
        # Then post with media
        body = %{
          text: String.slice(text, 0, 280),
          media: %{media_ids: [media_id]}
        }

        case twitter_request(:post, "/tweets", credentials, body) do
          {:ok, %{"data" => %{"id" => tweet_id}}} ->
            post_url = "https://twitter.com/i/status/#{tweet_id}"
            Logger.info("Twitter: Posted tweet #{tweet_id} with media")
            {:ok, %{post_id: tweet_id, post_url: post_url}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, "Media upload failed: #{reason}"}
    end
  end

  defp upload_media(media_url, credentials) do
    # First download the image
    case Req.get(media_url) do
      {:ok, %{status: 200, body: binary}} ->
        # Get the content type from the response headers
        content_type = detect_content_type(binary)

        # Upload to Twitter
        # Twitter API v2 requires creating an init request then appending
        init_body = %{
          command: "INIT",
          total_bytes: byte_size(binary),
          media_type: content_type
        }

        case twitter_request(:post, "/media/upload", credentials, init_body) do
          {:ok, %{"media_id_string" => media_id}} ->
            # Append the media
            # For simplicity, we'll do a single chunk append
            append_body = %{
              command: "APPEND",
              media_id: media_id,
              media_data: Base.encode64(binary),
              segment_index: 0
            }

            case twitter_request(:post, "/media/upload", credentials, append_body) do
              {:ok, _} ->
                # Finalize
                finalize_body = %{command: "FINALIZE", media_id: media_id}

                case twitter_request(:post, "/media/upload", credentials, finalize_body) do
                  {:ok, %{"media_id_string" => final_id}} -> {:ok, final_id}
                  {:ok, %{"media_id" => final_id}} -> {:ok, to_string(final_id)}
                  {:error, reason} -> {:error, reason}
                end

              {:error, reason} ->
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, "Failed to fetch image: #{reason}"}
    end
  end

  defp twitter_request(method, path, credentials, body) do
    url = @base_url <> path

    headers = [
      {"Authorization", "Bearer #{credentials.twitter_access_token}"},
      {"Content-Type", "application/json"}
    ]

    case method do
      :post ->
        case Req.post(url, json: body, headers: headers) do
          {:ok, %{status: status, body: body}} when status in 200..299 ->
            {:ok, body}

          {:ok, %{status: status, body: body}} when status >= 400 ->
            Logger.error("Twitter API error: #{status} - #{inspect(body)}")
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
