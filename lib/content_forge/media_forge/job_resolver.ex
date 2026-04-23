defmodule ContentForge.MediaForge.JobResolver do
  @moduledoc """
  Shared state-transition helper for asynchronous Media Forge jobs.

  Both code paths that resolve an async Media Forge job call through this
  module so the terminal transition is applied in exactly one place:

    * the pollers inside `ContentForge.Jobs.ImageGenerator` and
      `ContentForge.Jobs.VideoProducer`, which read the current record and
      pass it in directly;
    * the webhook controller at `POST /webhooks/media_forge`, which looks
      up the record by Media Forge job id and dispatches here.

  Every entry point is idempotent: records already in a terminal state
  return `:noop` and no update is issued. This keeps the poller and the
  webhook safe to race each other - whichever arrives first wins, the
  other returns `:noop` on its next pass.
  """

  alias ContentForge.ContentGeneration
  alias ContentForge.ContentGeneration.Draft
  alias ContentForge.Publishing
  alias ContentForge.Publishing.VideoJob

  @type event :: {:done, map()} | {:failed, binary()}
  @type image_outcome ::
          {:ok, :done, binary()}
          | {:ok, :failed, binary()}
          | {:ok, :noop}
          | {:error, term()}
  @type video_outcome ::
          {:ok, :done, binary()}
          | {:ok, :failed, binary()}
          | {:ok, :noop}
          | {:error, term()}
  @type outcome :: image_outcome() | video_outcome()

  # ---------------------------------------------------------------------------
  # Webhook entry point: look up the record by job id, dispatch, and return.
  # ---------------------------------------------------------------------------

  @doc """
  Resolves a Media Forge job by id. Searches both image-generation drafts
  and video jobs; returns `{:error, :not_found}` when neither matches.
  """
  @spec resolve_by_job_id(binary(), event()) :: outcome()
  def resolve_by_job_id(job_id, event) when is_binary(job_id) do
    case lookup_record(job_id) do
      nil -> {:error, :not_found}
      record -> apply_event(record, event)
    end
  end

  defp lookup_record(job_id) do
    ContentGeneration.get_draft_by_media_forge_job_id(job_id) ||
      Publishing.get_video_job_by_media_forge_job_id(job_id)
  end

  defp apply_event(%Draft{} = draft, {:done, result}), do: apply_image_done(draft, result)
  defp apply_event(%Draft{} = draft, {:failed, reason}), do: apply_image_failed(draft, reason)
  defp apply_event(%VideoJob{} = job, {:done, result}), do: apply_video_done(job, result)
  defp apply_event(%VideoJob{} = job, {:failed, reason}), do: apply_video_failed(job, reason)

  # ---------------------------------------------------------------------------
  # Image-generation draft transitions
  # ---------------------------------------------------------------------------

  @spec apply_image_done(Draft.t(), map()) :: image_outcome()
  def apply_image_done(%Draft{} = draft, result) do
    cond do
      image_terminal?(draft) ->
        {:ok, :noop}

      is_binary(url = extract_image_url(result)) ->
        {:ok, _} = ContentGeneration.update_draft(draft, %{image_url: url, error: nil})
        {:ok, :done, url}

      true ->
        apply_image_failed(draft, "Media Forge reported done without an image url")
    end
  end

  @spec apply_image_failed(Draft.t(), binary()) :: image_outcome()
  def apply_image_failed(%Draft{} = draft, reason) do
    case image_terminal?(draft) do
      true ->
        {:ok, :noop}

      false ->
        {:ok, _} =
          ContentGeneration.update_draft(draft, %{status: "blocked", error: reason})

        {:ok, :failed, reason}
    end
  end

  defp image_terminal?(%Draft{status: status}) when status in ["blocked", "published"], do: true
  defp image_terminal?(%Draft{image_url: url}) when is_binary(url) and url != "", do: true
  defp image_terminal?(_), do: false

  defp extract_image_url(%{"image_url" => url}) when is_binary(url) and url != "", do: url
  defp extract_image_url(%{"url" => url}) when is_binary(url) and url != "", do: url

  defp extract_image_url(%{"result" => %{"image_url" => url}}) when is_binary(url) and url != "",
    do: url

  defp extract_image_url(%{"result" => %{"url" => url}}) when is_binary(url) and url != "",
    do: url

  defp extract_image_url(_), do: nil

  # ---------------------------------------------------------------------------
  # Video job transitions
  # ---------------------------------------------------------------------------

  @spec apply_video_done(VideoJob.t(), map()) :: video_outcome()
  def apply_video_done(%VideoJob{} = job, result) do
    cond do
      video_terminal?(job) ->
        {:ok, :noop}

      is_binary(key = extract_video_key(result)) ->
        {:ok, _} = Publishing.update_video_job_status(job, "encoded", %{"final" => key})
        {:ok, :done, key}

      true ->
        apply_video_failed(job, "Media Forge reported done without an output key")
    end
  end

  @spec apply_video_failed(VideoJob.t(), binary()) :: video_outcome()
  def apply_video_failed(%VideoJob{} = job, reason) do
    case video_terminal?(job) do
      true ->
        {:ok, :noop}

      false ->
        {:ok, failed} = Publishing.update_video_job_status(job, "failed", %{})
        {:ok, _} = Publishing.update_video_job(failed, %{error: reason})
        {:ok, :failed, reason}
    end
  end

  defp video_terminal?(%VideoJob{status: status})
       when status in ["encoded", "uploaded", "failed"],
       do: true

  defp video_terminal?(_), do: false

  defp extract_video_key(%{"output_r2_key" => key}) when is_binary(key) and key != "", do: key
  defp extract_video_key(%{"r2_key" => key}) when is_binary(key) and key != "", do: key
  defp extract_video_key(%{"url" => key}) when is_binary(key) and key != "", do: key

  defp extract_video_key(%{"result" => %{"output_r2_key" => key}})
       when is_binary(key) and key != "",
       do: key

  defp extract_video_key(%{"result" => %{"r2_key" => key}}) when is_binary(key) and key != "",
    do: key

  defp extract_video_key(%{"result" => %{"url" => key}}) when is_binary(key) and key != "",
    do: key

  defp extract_video_key(_), do: nil
end
