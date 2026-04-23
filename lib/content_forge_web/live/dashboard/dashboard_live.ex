defmodule ContentForgeWeb.Live.Dashboard.DashboardLive do
  @moduledoc """
  Main Dashboard LiveView - entry point and navigation hub.
  """
  use ContentForgeWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <div>
        <h1 class="text-3xl font-bold">Dashboard</h1>
        <p class="text-base-content/70 mt-1">ContentForge Management Console</p>
      </div>
      
    <!-- Navigation Cards -->
      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-4">
        <a href={~p"/dashboard/products"} class="card bg-base-200 hover:bg-base-300 transition-colors">
          <div class="card-body">
            <div class="flex items-center gap-3">
              <div class="p-2 bg-primary/20 rounded-lg">
                <.icon name="hero-cube" class="size-6 text-primary" />
              </div>
              <div>
                <h3 class="font-semibold">Products</h3>
                <p class="text-xs text-base-content/70">Manage content products</p>
              </div>
            </div>
          </div>
        </a>

        <a href={~p"/dashboard/drafts"} class="card bg-base-200 hover:bg-base-300 transition-colors">
          <div class="card-body">
            <div class="flex items-center gap-3">
              <div class="p-2 bg-warning/20 rounded-lg">
                <.icon name="hero-document-text" class="size-6 text-warning" />
              </div>
              <div>
                <h3 class="font-semibold">Draft Review</h3>
                <p class="text-xs text-base-content/70">Review and approve drafts</p>
              </div>
            </div>
          </div>
        </a>

        <a href={~p"/dashboard/schedule"} class="card bg-base-200 hover:bg-base-300 transition-colors">
          <div class="card-body">
            <div class="flex items-center gap-3">
              <div class="p-2 bg-info/20 rounded-lg">
                <.icon name="hero-calendar" class="size-6 text-info" />
              </div>
              <div>
                <h3 class="font-semibold">Schedule</h3>
                <p class="text-xs text-base-content/70">Calendar and timeline</p>
              </div>
            </div>
          </div>
        </a>

        <a href={~p"/dashboard/video"} class="card bg-base-200 hover:bg-base-300 transition-colors">
          <div class="card-body">
            <div class="flex items-center gap-3">
              <div class="p-2 bg-error/20 rounded-lg">
                <.icon name="hero-film" class="size-6 text-error" />
              </div>
              <div>
                <h3 class="font-semibold">Video Production</h3>
                <p class="text-xs text-base-content/70">Pipeline status board</p>
              </div>
            </div>
          </div>
        </a>

        <a
          href={~p"/dashboard/performance"}
          class="card bg-base-200 hover:bg-base-300 transition-colors"
        >
          <div class="card-body">
            <div class="flex items-center gap-3">
              <div class="p-2 bg-success/20 rounded-lg">
                <.icon name="hero-chart-bar" class="size-6 text-success" />
              </div>
              <div>
                <h3 class="font-semibold">Performance</h3>
                <p class="text-xs text-base-content/70">Engagement and trends</p>
              </div>
            </div>
          </div>
        </a>

        <a href={~p"/dashboard/clips"} class="card bg-base-200 hover:bg-base-300 transition-colors">
          <div class="card-body">
            <div class="flex items-center gap-3">
              <div class="p-2 bg-secondary/20 rounded-lg">
                <.icon name="hero-scissors" class="size-6 text-secondary" />
              </div>
              <div>
                <h3 class="font-semibold">Clip Queue</h3>
                <p class="text-xs text-base-content/70">Approve flagged segments</p>
              </div>
            </div>
          </div>
        </a>
      </div>
      
    <!-- Quick Stats -->
      <div class="card bg-base-200">
        <div class="card-body">
          <h2 class="card-title">Quick Overview</h2>
          <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mt-4">
            <div class="stat">
              <div class="stat-title text-xs">Total Products</div>
              <div class="stat-value text-2xl">—</div>
            </div>
            <div class="stat">
              <div class="stat-title text-xs">Active Drafts</div>
              <div class="stat-value text-2xl">—</div>
            </div>
            <div class="stat">
              <div class="stat-title text-xs">Published Posts</div>
              <div class="stat-value text-2xl">—</div>
            </div>
            <div class="stat">
              <div class="stat-title text-xs">Video Jobs</div>
              <div class="stat-value text-2xl">—</div>
            </div>
          </div>
          <p class="text-xs text-base-content/50 mt-4">
            Use the navigation cards above to access detailed views
          </p>
        </div>
      </div>
    </div>
    """
  end
end
