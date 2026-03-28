defmodule ContentForgeWeb.Live.Dashboard.Clips.QueueLive do
  require Logger

  @moduledoc """
  LiveView for clip queue - approve flagged segments for short-form production.
  """
  use ContentForgeWeb, :live_view
  alias ContentForge.Metrics
  alias ContentForgeWeb.Live.Dashboard.Components

  @impl true
  def mount(_params, _session, socket) do
    pending_clips = Metrics.list_clip_flags(limit: 100)
    approved_clips = fetch_approved_clips()

    {:ok,
     assign(socket,
       pending_clips: pending_clips,
       approved_clips: approved_clips,
       selected_clip: nil
     )}
  end

  @impl true
  def handle_event("select_clip", %{"id" => id}, socket) do
    clip = Metrics.get_clip_flag(id)
    {:noreply, assign(socket, selected_clip: clip)}
  end

  @impl true
  def handle_event("approve_clip", %{"id" => id}, socket) do
    clip = Metrics.get_clip_flag(id)

    case Metrics.approve_clip_flag(clip) do
      {:ok, _} ->
        Logger.info("Approved clip for production: #{id}")
        pending_clips = Metrics.list_clip_flags(limit: 100)
        approved_clips = fetch_approved_clips()

        {:noreply,
         assign(socket,
           pending_clips: pending_clips,
           approved_clips: approved_clips,
           selected_clip: nil
         )}

      {:error, changeset} ->
        Logger.error("Failed to approve clip: #{inspect(changeset.errors)}")
        {:noreply, put_flash(socket, :error, "Failed to approve clip")}
    end
  end

  @impl true
  def handle_event("close_detail", _params, socket) do
    {:noreply, assign(socket, selected_clip: nil)}
  end

  defp fetch_approved_clips do
    Metrics.list_clip_flags(limit: 100)
    |> Enum.filter(fn flag ->
      data = flag.engagement_spike_data || %{}
      !!data["approved_for_production"]
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h1 class="text-2xl font-bold">Clip Queue</h1>
        <p class="text-base-content/70">Approve flagged segments for short-form production</p>
      </div>
      
    <!-- Stats -->
      <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
        <div class="stat bg-base-200">
          <div class="stat-title">Pending</div>
          <div class="stat-value text-warning">{length(@pending_clips)}</div>
        </div>
        <div class="stat bg-base-200">
          <div class="stat-title">Approved</div>
          <div class="stat-value text-success">{length(@approved_clips)}</div>
        </div>
        <div class="stat bg-base-200">
          <div class="stat-title">YouTube</div>
          <div class="stat-value">
            {Enum.filter(@pending_clips, &(&1.platform == "youtube")) |> length}
          </div>
        </div>
        <div class="stat bg-base-200">
          <div class="stat-title">TikTok</div>
          <div class="stat-value">
            {Enum.filter(@pending_clips, &(&1.platform == "tiktok")) |> length}
          </div>
        </div>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <!-- Pending Clips -->
        <div class="space-y-4">
          <h2 class="font-semibold">Pending Approval ({length(@pending_clips)})</h2>
          <div class="space-y-2">
            <div
              :for={clip <- @pending_clips}
              class={"card bg-base-200 hover:bg-base-300 cursor-pointer transition-colors #{if @selected_clip && @selected_clip.id == clip.id, do: "border-2 border-primary"}"}
              phx-click="select_clip"
              phx-value-id={clip.id}
            >
              <div class="card-body p-4">
                <div class="flex justify-between items-start">
                  <div>
                    <div class="flex items-center gap-2">
                      <span class="font-semibold">{clip.suggested_title}</span>
                      <span class="badge badge-sm badge-outline">{clip.platform}</span>
                    </div>
                    <p class="text-xs text-base-content/70 mt-1">
                      Video: {String.slice(clip.video_platform_id || "", 0, 20)}...
                    </p>
                  </div>
                  <Components.status_badge status="pending" />
                </div>

                <div class="flex gap-4 mt-2 text-sm">
                  <span>
                    <.icon name="hero-clock" class="size-3 inline" />
                    {format_time(clip.start_seconds)} - {format_time(clip.end_seconds)}
                  </span>
                  <span :if={clip.segment_views}>
                    <.icon name="hero-eye" class="size-3 inline" />
                    {clip.segment_views} views
                  </span>
                  <span :if={clip.segment_engagement_rate} class="text-success">
                    <.icon name="hero-chart-bar" class="size-3 inline" />
                    {Float.round(clip.segment_engagement_rate, 1)}% eng
                  </span>
                </div>
              </div>
            </div>

            <div :if={length(@pending_clips) == 0} class="text-center py-8 text-base-content/70">
              <.icon name="hero-video-camera" class="size-12 mx-auto mb-4 opacity-50" />
              <p>No clips pending approval</p>
            </div>
          </div>
        </div>
        
    <!-- Detail / Approved Panel -->
        <div class="space-y-4">
          <div :if={@selected_clip} class="card bg-base-200 sticky top-4">
            <div class="card-body">
              <div class="flex justify-between items-start">
                <h2 class="card-title">Clip Details</h2>
                <button phx-click="close_detail" class="btn btn-ghost btn-sm btn-circle">
                  <.icon name="hero-x" class="size-4" />
                </button>
              </div>
              
    <!-- Segment Info -->
              <div class="bg-base-300 rounded-lg p-4 mt-4">
                <h3 class="font-semibold mb-2">Segment</h3>
                <div class="grid grid-cols-2 gap-4 text-sm">
                  <div>
                    <span class="text-base-content/70">Start</span>
                    <p class="font-mono">{format_time(@selected_clip.start_seconds)}</p>
                  </div>
                  <div>
                    <span class="text-base-content/70">End</span>
                    <p class="font-mono">{format_time(@selected_clip.end_seconds)}</p>
                  </div>
                  <div>
                    <span class="text-base-content/70">Duration</span>
                    <p class="font-mono">
                      {@selected_clip.end_seconds - @selected_clip.start_seconds}s
                    </p>
                  </div>
                  <div>
                    <span class="text-base-content/70">Platform</span>
                    <p>{@selected_clip.platform}</p>
                  </div>
                </div>
              </div>
              
    <!-- Engagement Data -->
              <div
                :if={@selected_clip.segment_views || @selected_clip.segment_engagement_rate}
                class="bg-base-300 rounded-lg p-4 mt-4"
              >
                <h3 class="font-semibold mb-2">Engagement</h3>
                <div class="grid grid-cols-2 gap-4 text-sm">
                  <div :if={@selected_clip.segment_views}>
                    <span class="text-base-content/70">Views</span>
                    <p class="font-mono">{@selected_clip.segment_views}</p>
                  </div>
                  <div :if={@selected_clip.segment_engagement_rate}>
                    <span class="text-base-content/70">Engagement Rate</span>
                    <p class="font-mono text-success">
                      {Float.round(@selected_clip.segment_engagement_rate, 1)}%
                    </p>
                  </div>
                </div>
              </div>
              
    <!-- Engagement Spike Data -->
              <div :if={@selected_clip.engagement_spike_data} class="bg-base-300 rounded-lg p-4 mt-4">
                <h3 class="font-semibold mb-2">Spike Analysis</h3>
                <div class="text-sm">
                  <p>
                    Type:
                    <span class="badge badge-sm">
                      {@selected_clip.engagement_spike_data["spike_type"] || "unknown"}
                    </span>
                  </p>
                  <p class="text-xs text-base-content/70 mt-1">
                    Detected: {Components.format_datetime(
                      @selected_clip.engagement_spike_data["detected_at"]
                    )}
                  </p>
                </div>
              </div>
              
    <!-- Retention Curve -->
              <div :if={@selected_clip.retention_curve} class="bg-base-300 rounded-lg p-4 mt-4">
                <h3 class="font-semibold mb-2">Retention Curve</h3>
                <div class="h-24 flex items-end gap-px">
                  <%= for {time, value} <- parse_retention(@selected_clip.retention_curve) do %>
                    <div
                      class="flex-1 bg-primary/70 hover:bg-primary transition-colors"
                      style={"height: #{value}%"}
                      title={"#{time}s: #{value}%"}
                    >
                    </div>
                  <% end %>
                </div>
              </div>
              
    <!-- Actions -->
              <div class="flex gap-2 justify-end mt-4">
                <button
                  class="btn btn-primary"
                  phx-click="approve_clip"
                  phx-value-id={@selected_clip.id}
                >
                  <.icon name="hero-check" class="size-4" /> Approve for Production
                </button>
              </div>
            </div>
          </div>
          
    <!-- Approved Clips -->
          <div :if={!@selected_clip} class="space-y-2">
            <h2 class="font-semibold">Approved for Production ({length(@approved_clips)})</h2>
            <div :for={clip <- @approved_clips} class="card bg-success/10 border border-success/30">
              <div class="card-body p-3">
                <div class="flex justify-between items-center">
                  <div>
                    <span class="font-medium">{clip.suggested_title}</span>
                    <span class="badge badge-sm badge-success ml-2">{clip.platform}</span>
                  </div>
                  <span class="text-xs text-success">
                    <.icon name="hero-check" class="size-3" /> Approved
                  </span>
                </div>
                <p class="text-xs text-base-content/70 mt-1">
                  {format_time(clip.start_seconds)} - {format_time(clip.end_seconds)}
                </p>
              </div>
            </div>

            <div :if={length(@approved_clips) == 0} class="text-center py-4 text-base-content/70">
              No approved clips yet
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_time(seconds) do
    minutes = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{minutes}m#{secs}s"
  end

  defp parse_retention(nil), do: []

  defp parse_retention(%{"data" => data}) when is_list(data) do
    data
    |> Enum.take(30)
    |> Enum.map(fn
      %{"time" => t, "value" => v} -> {to_int(t), to_float(v)}
      {t, v} when is_binary(t) -> {to_int(t), to_float(v)}
      {t, v} -> {t, v * 1.0}
    end)
    |> Enum.map(fn {t, v} -> {t, max(v, 1.0)} end)
  end

  defp parse_retention(_), do: []

  defp to_int(v) when is_binary(v), do: String.to_integer(v)
  defp to_int(v) when is_integer(v), do: v
  defp to_int(v), do: round(v)

  defp to_float(v) when is_binary(v), do: String.to_float(v)
  defp to_float(v) when is_float(v), do: v
  defp to_float(v) when is_integer(v), do: v * 1.0
end
