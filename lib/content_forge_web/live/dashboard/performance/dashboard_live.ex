defmodule ContentForgeWeb.Live.Dashboard.Performance.DashboardLive do
  require Logger

  @moduledoc """
  LiveView for performance dashboard: engagement trends, retention curves, clip queue.
  """
  use ContentForgeWeb, :live_view
  alias ContentForge.Metrics
  alias ContentForge.Publishing
  alias ContentForge.Products
  alias ContentForgeWeb.Live.Dashboard.Components

  @impl true
  def mount(params, _session, socket) do
    products = Products.list_products()
    product_id = Map.get(params, "product", "")

    scoreboard = Metrics.list_scoreboard_entries(product_id: product_id, limit: 50)
    clip_flags = Metrics.list_clip_flags(limit: 20)
    engagement_metrics = fetch_engagement_metrics(product_id)

    {:ok,
     assign(socket,
       products: products,
       product_filter: product_id,
       scoreboard: scoreboard,
       clip_flags: clip_flags,
       engagement_metrics: engagement_metrics,
       active_tab: "overview"
     )}
  end

  @impl true
  def handle_event("filter_product", %{"product" => product_id}, socket) do
    scoreboard = Metrics.list_scoreboard_entries(product_id: product_id, limit: 50)
    clip_flags = Metrics.list_clip_flags(limit: 20)
    engagement_metrics = fetch_engagement_metrics(product_id)

    {:noreply,
     assign(socket,
       product_filter: product_id,
       scoreboard: scoreboard,
       clip_flags: clip_flags,
       engagement_metrics: engagement_metrics
     )}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: tab)}
  end

  @impl true
  def handle_event("approve_clip", %{"id" => id}, socket) do
    clip = Metrics.get_clip_flag(id)

    case Metrics.approve_clip_flag(clip) do
      {:ok, _} ->
        Logger.info("Approved clip flag: #{id}")
        clip_flags = Metrics.list_clip_flags(limit: 20)
        {:noreply, assign(socket, clip_flags: clip_flags)}

      {:error, changeset} ->
        Logger.error("Failed to approve clip: #{inspect(changeset.errors)}")
        {:noreply, put_flash(socket, :error, "Failed to approve clip")}
    end
  end

  defp fetch_engagement_metrics("") do
    Publishing.list_published_posts(limit: 100)
    |> Enum.group_by(& &1.platform)
    |> Enum.map(fn {platform, posts} ->
      {platform, calculate_metrics(posts)}
    end)
  end

  defp fetch_engagement_metrics(product_id) do
    Publishing.list_published_posts(product_id: product_id, limit: 100)
    |> Enum.group_by(& &1.platform)
    |> Enum.map(fn {platform, posts} ->
      {platform, calculate_metrics(posts)}
    end)
  end

  defp calculate_metrics(posts) do
    total = length(posts)

    engagement_total =
      Enum.reduce(posts, 0, fn post, acc ->
        data = post.engagement_data || %{}
        (data["likes"] || 0) + (data["comments"] || 0) + (data["shares"] || 0) + acc
      end)

    %{
      total_posts: total,
      total_engagement: engagement_total,
      avg_engagement: if(total > 0, do: engagement_total / total, else: 0)
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
        <div>
          <h1 class="text-2xl font-bold">Performance Dashboard</h1>
          <p class="text-base-content/70">Engagement trends, retention curves, and clips</p>
        </div>
        <select
          class="select select-bordered"
          name="product"
          phx-change="filter_product"
        >
          <option value="">All Products</option>
          <option :for={product <- @products} value={product.id}>
            {product.name}
          </option>
        </select>
      </div>
      
    <!-- Tabs -->
      <div role="tablist" class="tabs tabs-boxed">
        <button
          role="tab"
          class={["tab", @active_tab == "overview" && "tab-active"]}
          phx-click="switch_tab"
          phx-value-tab="overview"
        >
          Overview
        </button>
        <button
          role="tab"
          class={["tab", @active_tab == "trends" && "tab-active"]}
          phx-click="switch_tab"
          phx-value-tab="trends"
        >
          Trends
        </button>
        <button
          role="tab"
          class={["tab", @active_tab == "clips" && "tab-active"]}
          phx-click="switch_tab"
          phx-value-tab="clips"
        >
          Clips <span class="badge badge-xs badge-primary">{length(@clip_flags)}</span>
        </button>
      </div>
      
    <!-- Overview Tab -->
      <div :if={@active_tab == "overview"}>
        <!-- Platform Stats -->
        <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-4">
          <div :for={{platform, metrics} <- @engagement_metrics} class="stat bg-base-200">
            <div class="stat-title capitalize text-xs">{platform}</div>
            <div class="stat-value text-lg">{metrics.total_posts}</div>
            <div class="stat-desc">Avg: {Float.round(metrics.avg_engagement, 1)}</div>
          </div>
        </div>
        
    <!-- Recent Winners -->
        <div class="card bg-base-200 mt-6">
          <div class="card-body">
            <h2 class="card-title">Top Performing Content</h2>
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Platform</th>
                    <th>Type</th>
                    <th>AI Score</th>
                    <th>Actual</th>
                    <th>Delta</th>
                    <th>Outcome</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={
                    entry <- Enum.take(Enum.filter(@scoreboard, &(&1.outcome == "winner")), 10)
                  }>
                    <td>{entry.platform}</td>
                    <td>{entry.content_type}</td>
                    <td><Components.score_display score={entry.composite_ai_score || 0} /></td>
                    <td><Components.score_display score={entry.actual_engagement_score || 0} /></td>
                    <td class={
                      (entry.delta && entry.delta > 0 && "text-success") ||
                        (entry.delta && entry.delta < 0 && "text-error") || ""
                    }>
                      {if entry.delta, do: Float.round(entry.delta, 1), else: "—"}
                    </td>
                    <td><Components.status_badge status={entry.outcome || "pending"} /></td>
                  </tr>
                </tbody>
              </table>
            </div>
            <div
              :if={Enum.filter(@scoreboard, &(&1.outcome == "winner")) == []}
              class="text-center py-4 text-base-content/70"
            >
              No winner content yet
            </div>
          </div>
        </div>
      </div>
      
    <!-- Trends Tab -->
      <div :if={@active_tab == "trends"} class="space-y-6">
        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <!-- Engagement by Platform -->
          <div class="card bg-base-200">
            <div class="card-body">
              <h2 class="card-title">Engagement by Platform</h2>
              <div class="space-y-4">
                <div :for={{platform, metrics} <- @engagement_metrics}>
                  <div class="flex justify-between items-center">
                    <span class="capitalize font-medium">{platform}</span>
                    <div class="flex items-center gap-2">
                      <span>{metrics.total_engagement} eng</span>
                      <div class="w-32 h-2 bg-base-300 rounded overflow-hidden">
                        <div
                          class="h-full bg-primary"
                          style={"width: #{max(metrics.total_engagement / 1000 * 100, 5)}%"}
                        >
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
          
    <!-- Average Engagement -->
          <div class="card bg-base-200">
            <div class="card-body">
              <h2 class="card-title">Average Engagement per Post</h2>
              <div class="space-y-4">
                <div :for={{platform, metrics} <- @engagement_metrics}>
                  <div class="flex justify-between items-center">
                    <span class="capitalize font-medium">{platform}</span>
                    <span class="text-lg font-mono">
                      {Float.round(metrics.avg_engagement, 1)}
                    </span>
                  </div>
                  <div class="w-full h-2 bg-base-300 rounded overflow-hidden mt-1">
                    <div
                      class={"h-full #{avg_engagement_color(metrics.avg_engagement)}"}
                      style={"width: #{min(metrics.avg_engagement * 10, 100)}%"}
                    >
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
        
    <!-- Scoreboard Table -->
        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title">Scoreboard (Recent)</h2>
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Platform</th>
                    <th>Type</th>
                    <th>Angle</th>
                    <th>AI Score</th>
                    <th>Actual</th>
                    <th>Delta</th>
                    <th>Date</th>
                    <th>Outcome</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @scoreboard}>
                    <td>{entry.platform}</td>
                    <td>{entry.content_type}</td>
                    <td>{entry.angle || "—"}</td>
                    <td><Components.score_display score={entry.composite_ai_score || 0} /></td>
                    <td>
                      <span :if={entry.actual_engagement_score}>
                        <Components.score_display score={entry.actual_engagement_score} />
                      </span>
                      <span :if={!entry.actual_engagement_score} class="text-base-content/50">—</span>
                    </td>
                    <td class={
                      (entry.delta && entry.delta > 0 && "text-success") ||
                        (entry.delta && entry.delta < 0 && "text-error") || ""
                    }>
                      {if entry.delta, do: Float.round(entry.delta, 1), else: "—"}
                    </td>
                    <td class="text-xs">
                      {Components.format_datetime(entry.measured_at || entry.inserted_at)}
                    </td>
                    <td><Components.status_badge status={entry.outcome || "pending"} /></td>
                  </tr>
                </tbody>
              </table>
            </div>
            <div :if={length(@scoreboard) == 0} class="text-center py-4 text-base-content/70">
              No scoreboard entries yet
            </div>
          </div>
        </div>
      </div>
      
    <!-- Clips Tab -->
      <div :if={@active_tab == "clips"} class="space-y-4">
        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title">Flagged Clip Segments</h2>
            <p class="text-sm text-base-content/70 mb-4">
              High-engagement segments identified from videos for short-form production
            </p>
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Video</th>
                    <th>Platform</th>
                    <th>Segment</th>
                    <th>Title</th>
                    <th>Views</th>
                    <th>Eng Rate</th>
                    <th>Status</th>
                    <th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={flag <- @clip_flags}>
                    <td class="font-mono text-xs">
                      {String.slice(flag.video_platform_id || "", 0, 12)}...
                    </td>
                    <td>{flag.platform}</td>
                    <td>{format_time(flag.start_seconds)} - {format_time(flag.end_seconds)}</td>
                    <td>{flag.suggested_title}</td>
                    <td>{flag.segment_views || "—"}</td>
                    <td>
                      <span :if={flag.segment_engagement_rate}>
                        {Float.round(flag.segment_engagement_rate, 1)}%
                      </span>
                      <span :if={!flag.segment_engagement_rate}>—</span>
                    </td>
                    <td>
                      <Components.status_badge status={clip_status(flag)} />
                    </td>
                    <td>
                      <button
                        :if={!approved?(flag)}
                        class="btn btn-xs btn-primary"
                        phx-click="approve_clip"
                        phx-value-id={flag.id}
                      >
                        Approve
                      </button>
                      <span :if={approved?(flag)} class="text-success text-xs">
                        <.icon name="hero-check" class="size-3" />
                      </span>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
            <div :if={length(@clip_flags) == 0} class="text-center py-8 text-base-content/70">
              No clip flags yet
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp avg_engagement_color(avg) when avg >= 50, do: "bg-success"
  defp avg_engagement_color(avg) when avg >= 20, do: "bg-warning"
  defp avg_engagement_color(_), do: "bg-error"

  defp format_time(seconds) do
    minutes = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{minutes}m#{secs}s"
  end

  defp clip_status(flag) do
    data = flag.engagement_spike_data || %{}
    if data["approved_for_production"], do: "approved", else: "pending"
  end

  defp approved?(flag) do
    data = flag.engagement_spike_data || %{}
    !!data["approved_for_production"]
  end
end
