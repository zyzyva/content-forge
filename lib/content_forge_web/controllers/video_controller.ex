defmodule ContentForgeWeb.VideoController do
  use ContentForgeWeb, :controller

  alias ContentForge.Metrics

  action_fallback ContentForgeWeb.FallbackController

  # POST /api/v1/videos/:video_id/clip
  # Approves a flagged segment for short-form clip production
  def clip(conn, %{"video_id" => video_id, "flag_id" => flag_id}) do
    # Get the clip flag
    flag = Metrics.get_clip_flag(flag_id)

    if flag do
      # Verify it belongs to the requested video
      if flag.video_platform_id == video_id or to_string(flag.video_id) == video_id do
        # Mark as approved for clip production
        # This could trigger a job to generate the short-form clip
        {:ok, updated_flag} = Metrics.approve_clip_flag(flag)

        json(conn, %{
          message: "Segment approved for clip production",
          clip: %{
            id: updated_flag.id,
            video_id: video_id,
            start_seconds: updated_flag.start_seconds,
            end_seconds: updated_flag.end_seconds,
            suggested_title: updated_flag.suggested_title,
            status: "approved"
          }
        })
      else
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Flag does not belong to this video"})
      end
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "Clip flag not found"})
    end
  end

  # Alternative: approve by auto-selecting best flag for a video
  def clip(conn, %{"video_id" => video_id}) do
    # Get all flags for this video and select the best one (highest engagement)
    flags = Metrics.get_clip_flags_for_video(video_id)

    if flags == [] do
      conn
      |> put_status(:not_found)
      |> json(%{error: "No clip flags found for this video"})
    else
      # Select the flag with highest engagement rate
      best_flag =
        Enum.max_by(flags, fn f -> f.segment_engagement_rate || 0 end, &>=/2, fn -> nil end)

      if best_flag && best_flag.segment_engagement_rate do
        {:ok, updated_flag} = Metrics.approve_clip_flag(best_flag)

        json(conn, %{
          message: "Best segment approved for clip production",
          clip: %{
            id: updated_flag.id,
            video_id: video_id,
            start_seconds: updated_flag.start_seconds,
            end_seconds: updated_flag.end_seconds,
            suggested_title: updated_flag.suggested_title,
            engagement_rate: updated_flag.segment_engagement_rate,
            status: "approved"
          }
        })
      else
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "No suitable clip flags found with engagement data"})
      end
    end
  end
end
