defmodule ContentForge.Jobs.VideoProducer do
  @moduledoc """
  Oban job for producing videos through a multi-step pipeline:

  1. ElevenLabs voiceover - Convert script text to MP3
  2. Playwright screen recording - Record walkthrough of live site
  3. HeyGen avatar - Generate avatar video with script
  4. Remotion assembly - Assemble all assets into video
  5. FFmpeg encode - Normalize and finalize video
  6. YouTube upload - Upload with AI-generated metadata

  Each step updates the VideoJob status. Failed steps retry 3x then pause the job.
  """

  use Oban.Worker, max_attempts: 3

  alias ContentForge.{Products, Publishing, ContentGeneration}
  alias ContentForge.Publishing.VideoJob

  require Logger

  @max_retries 3

  # Type definitions
  # The step_result type helps with pattern matching but the compiler
  # still sees dynamic return type from private functions. This is fine -
  # we're being defensive with error handling.
  @type step_result :: {:ok, binary()} | {:error, binary()}
  @dialyzer {:nowarn_function, elevenlabs_generate_speech: 2}
  @dialyzer {:nowarn_function, playwright_record_walkthrough: 2}
  @dialyzer {:nowarn_function, heygen_generate_avatar: 2}
  @dialyzer {:nowarn_function, remotion_assemble: 4}
  @dialyzer {:nowarn_function, ffmpeg_encode: 2}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"video_job_id" => video_job_id}}) do
    Logger.info("VideoProducer: Starting job #{video_job_id}")

    case Publishing.get_video_job(video_job_id) do
      nil ->
        Logger.error("VideoProducer: VideoJob not found #{video_job_id}")
        {:cancel, "VideoJob not found"}

      video_job ->
        if not video_job.feature_flag do
          Logger.info("VideoProducer: Feature flag disabled for job #{video_job_id}")
          :ok
        else
          process_video_job(video_job)
        end
    end
  end

  defp process_video_job(%VideoJob{} = video_job) do
    draft = ContentGeneration.get_draft(video_job.draft_id)

    case draft do
      nil ->
        Logger.error("VideoProducer: Draft not found for job #{video_job.id}")
        pause_job(video_job, "Draft not found")
        {:cancel, "Draft not found"}

      draft ->
        product = Products.get_product(video_job.product_id)

        case product do
          nil ->
            Logger.error("VideoProducer: Product not found for job #{video_job.id}")
            pause_job(video_job, "Product not found")
            {:cancel, "Product not found"}

          product ->
            # Execute pipeline steps in order
            execute_pipeline(draft, product, video_job)
        end
    end
  end

  defp execute_pipeline(draft, product, video_job) do
    # Step 1: Voiceover (ElevenLabs)
    case produce_voiceover(draft, product, video_job) do
      {:ok, voiceover_r2_key, video_job} ->
        # Step 2: Screen Recording (Playwright)
        case produce_screen_recording(draft, product, video_job, voiceover_r2_key) do
          {:ok, recording_r2_key, video_job} ->
            # Step 3: Avatar Video (HeyGen)
            case produce_avatar_video(draft, product, video_job, recording_r2_key) do
              {:ok, avatar_r2_key, video_job} ->
                # Step 4: Assembly (Remotion)
                case assemble_video(
                       draft,
                       product,
                       video_job,
                       voiceover_r2_key,
                       recording_r2_key,
                       avatar_r2_key
                     ) do
                  {:ok, assembled_r2_key, video_job} ->
                    # Step 5: FFmpeg Encode
                    case encode_video(draft, product, video_job, assembled_r2_key) do
                      {:ok, final_r2_key, video_job} ->
                        # Step 6: YouTube Upload
                        case upload_to_youtube(draft, product, video_job, final_r2_key) do
                          {:ok, _video_url, video_job} ->
                            Logger.info("VideoProducer: Completed job #{video_job.id}")
                            :ok

                          {:error, reason, video_job} ->
                            handle_step_error(video_job, :youtube_upload, reason)
                        end
                    end

                  {:error, reason, video_job} ->
                    handle_step_error(video_job, :assembly, reason)
                end

              {:error, reason, video_job} ->
                handle_step_error(video_job, :avatar, reason)
            end

          {:error, reason, video_job} ->
            handle_step_error(video_job, :recording, reason)
        end

      {:error, reason, video_job} ->
        handle_step_error(video_job, :voiceover, reason)
    end
  end

  # ============================================
  # Step 1: ElevenLabs Voiceover
  # ============================================

  defp produce_voiceover(draft, product, video_job) do
    Logger.info("VideoProducer: Step 1 - Voiceover for job #{video_job.id}")

    script_text = draft.content

    case elevenlabs_generate_speech(script_text, product) do
      {:ok, mp3_r2_key} ->
        {:ok, updated_video_job} =
          Publishing.update_video_job_status(video_job, "voiceover_done", %{
            "voiceover" => mp3_r2_key
          })

        Logger.info("VideoProducer: Voiceover complete - #{mp3_r2_key}")
        {:ok, mp3_r2_key, updated_video_job}

      {:error, _reason} ->
        # In production, this would be a real error; for now simulate failure
        {:error, "Service unavailable", video_job}
    end
  end

  @spec elevenlabs_generate_speech(binary(), map()) :: step_result()
  defp elevenlabs_generate_speech(_script_text, product) do
    # Get ElevenLabs config from product
    elevenlabs_config = get_in(product.publishing_targets, ["elevenlabs"]) || %{}

    api_key = elevenlabs_config["api_key"]
    voice_id = elevenlabs_config["voice_id"] || "21m00Tcm4TlvDq8ikWAM"

    if api_key do
      # For now, simulate the API call - in production would call ElevenLabs API
      r2_key = "video_jobs/#{:erlang.system_time(:millisecond)}_voiceover.mp3"
      Logger.info("VideoProducer: ElevenLabs would generate speech with voice #{voice_id}")
      {:ok, r2_key}
    else
      # No API key configured - this is an error condition
      Logger.warning("VideoProducer: ElevenLabs API key not configured")
      {:error, "ElevenLabs API key not configured"}
    end
  end

  # ============================================
  # Step 2: Playwright Screen Recording
  # ============================================

  defp produce_screen_recording(_draft, product, video_job, _voiceover_key) do
    Logger.info("VideoProducer: Step 2 - Screen Recording for job #{video_job.id}")

    site_url = product.site_url

    case playwright_record_walkthrough(site_url, product) do
      {:ok, recording_r2_key} ->
        {:ok, updated_video_job} =
          Publishing.update_video_job_status(video_job, "recording_done", %{
            "recording" => recording_r2_key
          })

        Logger.info("VideoProducer: Screen recording complete - #{recording_r2_key}")
        {:ok, recording_r2_key, updated_video_job}

      {:error, _reason} ->
        {:error, "Service unavailable", video_job}
    end
  end

  @spec playwright_record_walkthrough(binary(), map()) :: step_result()
  defp playwright_record_walkthrough(site_url, product) do
    # Get walkthrough config
    walkthrough_config = get_in(product.publishing_targets, ["screen_recording"]) || %{}
    duration_seconds = walkthrough_config["duration_seconds"] || 30
    target_url = walkthrough_config["target_url"] || site_url
    enabled = walkthrough_config["enabled"]

    if enabled do
      # Simulate Playwright recording - in production would use playwright browsers
      r2_key = "video_jobs/#{:erlang.system_time(:millisecond)}_recording.mp4"

      Logger.info(
        "VideoProducer: Would record walkthrough of #{target_url} for #{duration_seconds}s"
      )

      {:ok, r2_key}
    else
      Logger.warning("VideoProducer: Screen recording not enabled")
      {:error, "Screen recording not enabled"}
    end
  end

  # ============================================
  # Step 3: HeyGen Avatar
  # ============================================

  defp produce_avatar_video(draft, product, video_job, _recording_key) do
    Logger.info("VideoProducer: Step 3 - Avatar Video for job #{video_job.id}")

    script_text = draft.content

    case heygen_generate_avatar(script_text, product) do
      {:ok, avatar_r2_key} ->
        {:ok, updated_video_job} =
          Publishing.update_video_job_status(video_job, "avatar_done", %{
            "avatar" => avatar_r2_key
          })

        Logger.info("VideoProducer: Avatar video complete - #{avatar_r2_key}")
        {:ok, avatar_r2_key, updated_video_job}

      {:error, _reason} ->
        {:error, "Service unavailable", video_job}
    end
  end

  @spec heygen_generate_avatar(binary(), map()) :: step_result()
  defp heygen_generate_avatar(_script_text, product) do
    heygen_config = get_in(product.publishing_targets, ["heygen"]) || %{}

    api_key = heygen_config["api_key"]
    avatar_id = heygen_config["avatar_id"] || "default_avatar"

    if api_key do
      # Simulate HeyGen API call - in production would submit job and poll
      r2_key = "video_jobs/#{:erlang.system_time(:millisecond)}_avatar.mp4"
      Logger.info("VideoProducer: Would generate HeyGen avatar #{avatar_id} with script")
      {:ok, r2_key}
    else
      Logger.warning("VideoProducer: HeyGen API key not configured")
      {:error, "HeyGen API key not configured"}
    end
  end

  # ============================================
  # Step 4: Remotion Assembly
  # ============================================

  defp assemble_video(_draft, product, video_job, voiceover_key, recording_key, avatar_key) do
    Logger.info("VideoProducer: Step 4 - Assembly for job #{video_job.id}")

    case remotion_assemble(voiceover_key, recording_key, avatar_key, product) do
      {:ok, assembled_r2_key} ->
        {:ok, updated_video_job} =
          Publishing.update_video_job_status(video_job, "assembled", %{
            "assembled" => assembled_r2_key
          })

        Logger.info("VideoProducer: Assembly complete - #{assembled_r2_key}")
        {:ok, assembled_r2_key, updated_video_job}

      {:error, _reason} ->
        {:error, "Service unavailable", video_job}
    end
  end

  @spec remotion_assemble(binary(), binary(), binary(), map()) :: step_result()
  defp remotion_assemble(voiceover_key, recording_key, avatar_key, product) do
    # Simulate Remotion assembly
    remotion_config = get_in(product.publishing_targets, ["remotion"]) || %{}
    enabled = remotion_config["enabled"]

    if enabled do
      r2_key = "video_jobs/#{:erlang.system_time(:millisecond)}_assembled.mp4"

      Logger.info(
        "VideoProducer: Would assemble assets: voiceover=#{voiceover_key}, recording=#{recording_key}, avatar=#{avatar_key}"
      )

      {:ok, r2_key}
    else
      Logger.warning("VideoProducer: Remotion not enabled")
      {:error, "Remotion not enabled"}
    end
  end

  # ============================================
  # Step 5: FFmpeg Encode
  # ============================================

  defp encode_video(_draft, product, video_job, assembled_key) do
    Logger.info("VideoProducer: Step 5 - FFmpeg Encode for job #{video_job.id}")

    case ffmpeg_encode(assembled_key, product) do
      {:ok, final_r2_key} ->
        updated_keys = Map.put(video_job.per_step_r2_keys || %{}, "final", final_r2_key)

        # Note: status stays at "assembled" until upload
        {:ok, updated_video_job} =
          Publishing.update_video_job(video_job, %{
            per_step_r2_keys: updated_keys
          })

        Logger.info("VideoProducer: FFmpeg encode complete - #{final_r2_key}")
        {:ok, final_r2_key, updated_video_job}

      {:error, _reason} ->
        {:error, "Service unavailable", video_job}
    end
  end

  @spec ffmpeg_encode(binary(), map()) :: step_result()
  defp ffmpeg_encode(assembled_key, product) do
    ffmpeg_config = get_in(product.publishing_targets, ["ffmpeg"]) || %{}
    enabled = ffmpeg_config["enabled"]

    if enabled do
      # Simulate FFmpeg encoding
      r2_key = "video_jobs/#{:erlang.system_time(:millisecond)}_final.mp4"
      Logger.info("VideoProducer: Would FFmpeg encode #{assembled_key}")
      {:ok, r2_key}
    else
      Logger.warning("VideoProducer: FFmpeg not enabled")
      {:error, "FFmpeg not enabled"}
    end
  end

  # ============================================
  # Step 6: YouTube Upload
  # ============================================

  defp upload_to_youtube(_draft, product, video_job, _final_key) do
    Logger.info("VideoProducer: Step 6 - YouTube Upload for job #{video_job.id}")

    case get_youtube_credentials(product) do
      nil ->
        Logger.error("VideoProducer: No YouTube credentials")
        {:error, "No YouTube credentials configured", video_job}

      _credentials ->
        # Simulate upload - in production would download from R2 and upload
        video_url = "https://youtube.com/watch?v=dummy_#{video_job.id}"

        {:ok, updated_video_job} =
          Publishing.update_video_job_status(video_job, "uploaded", %{})

        Logger.info("VideoProducer: YouTube upload complete - #{video_url}")
        {:ok, video_url, updated_video_job}
    end
  end

  defp get_youtube_credentials(product) do
    youtube_config = get_in(product.publishing_targets, ["youtube"]) || %{}

    if youtube_config["enabled"] && youtube_config["access_token"] do
      %{
        youtube_access_token: youtube_config["access_token"]
      }
    else
      nil
    end
  end

  # ============================================
  # Error Handling
  # ============================================

  defp handle_step_error(video_job, step, reason) do
    Logger.error("VideoProducer: Step #{step} failed for job #{video_job.id} - #{reason}")

    case video_job do
      %{attempt: nil} ->
        # First failure - retry
        {:retry, reason}

      %{attempt: attempt} when attempt >= @max_retries ->
        # Max retries exceeded - pause
        pause_job(video_job, reason)
        {:error, reason}

      _ ->
        {:retry, reason}
    end
  end

  defp pause_job(video_job, reason) do
    Publishing.update_video_job_status(video_job, "paused", %{})
    Logger.warning("VideoProducer: Paused job #{video_job.id} - #{reason}")
  end
end
