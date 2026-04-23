defmodule ContentForgeWeb.Live.Dashboard.Products.DetailLive do
  require Logger

  @moduledoc """
  LiveView for per-product details: snapshot status, brief, draft queue, publishing history.
  """
  use ContentForgeWeb, :live_view
  alias ContentForge.Products
  alias ContentForge.ContentGeneration
  alias ContentForge.Publishing
  alias ContentForgeWeb.Live.Dashboard.Components

  @impl true
  def mount(%{"id" => product_id}, _session, socket) do
    product = Products.get_product!(product_id)

    snapshots = Products.list_product_snapshots_for_product(product_id)
    brief = ContentGeneration.get_latest_content_brief_for_product(product_id)
    drafts = ContentGeneration.list_drafts_for_product(product_id)
    published_posts = Publishing.list_published_posts(product_id: product_id, limit: 10)

    {:ok,
     assign(socket,
       product: product,
       snapshots: snapshots,
       brief: brief,
       drafts: drafts,
       published_posts: published_posts,
       active_tab: "overview"
     )}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: tab)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Header -->
      <div class="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
        <div>
          <div class="flex items-center gap-2">
            <.link navigate={~p"/dashboard/products"} class="btn btn-ghost btn-sm">
              <.icon name="hero-arrow-left" class="size-4" />
            </.link>
            <h1 class="text-2xl font-bold">{@product.name}</h1>
          </div>
          <p class="text-base-content/70 ml-8">
            Voice: {@product.voice_profile}
          </p>
        </div>
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
          class={["tab", @active_tab == "briefs" && "tab-active"]}
          phx-click="switch_tab"
          phx-value-tab="briefs"
        >
          Briefs
        </button>
        <button
          role="tab"
          class={["tab", @active_tab == "drafts" && "tab-active"]}
          phx-click="switch_tab"
          phx-value-tab="drafts"
        >
          Drafts
        </button>
        <button
          role="tab"
          class={["tab", @active_tab == "history" && "tab-active"]}
          phx-click="switch_tab"
          phx-value-tab="history"
        >
          History
        </button>
      </div>
      
    <!-- Overview Tab -->
      <div
        :if={@active_tab == "overview"}
        class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4"
      >
        <Components.stat_card count={length(@snapshots)} label="Snapshots" />
        <Components.stat_card count={length(@drafts)} label="Total Drafts" />
        <Components.stat_card
          count={Enum.filter(@drafts, &(&1.status == "draft")) |> length}
          label="Draft"
        />
        <Components.stat_card count={length(@published_posts)} label="Published" />
      </div>
      
    <!-- Snapshots Section (always visible in overview) -->
      <div :if={@active_tab == "overview"} class="card bg-base-200">
        <div class="card-body">
          <h2 class="card-title">Recent Snapshots</h2>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Type</th>
                  <th>Created</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={snapshot <- Enum.take(@snapshots, 5)}>
                  <td>{snapshot.snapshot_type}</td>
                  <td>{Components.format_datetime(snapshot.inserted_at)}</td>
                  <td><Components.status_badge status={snapshot.status} /></td>
                </tr>
              </tbody>
            </table>
          </div>
          <div :if={length(@snapshots) == 0} class="text-center py-4 text-base-content/70">
            No snapshots yet
          </div>
        </div>
      </div>
      
    <!-- Current Brief -->
      <div :if={@active_tab == "overview" && @brief} class="card bg-base-200">
        <div class="card-body">
          <h2 class="card-title">Current Brief (v{@brief.version})</h2>
          <div class="prose prose-sm max-w-none">
            <p class="whitespace-pre-wrap">{String.slice(@brief.content, 0, 500)}...</p>
          </div>
          <div class="card-actions justify-end">
            <.link
              navigate={~p"/dashboard/drafts?product=#{@product.id}"}
              class="btn btn-sm btn-primary"
            >
              View All Briefs
            </.link>
          </div>
        </div>
      </div>
      
    <!-- Briefs Tab -->
      <div :if={@active_tab == "briefs"} class="card bg-base-200">
        <div class="card-body">
          <h2 class="card-title">Content Briefs</h2>
          <div :if={@brief} class="space-y-4">
            <div class="border border-base-300 rounded-lg p-4">
              <div class="flex justify-between items-start">
                <div>
                  <h3 class="font-semibold">Version {@brief.version}</h3>
                  <p class="text-sm text-base-content/70">
                    Created: {Components.format_datetime(@brief.inserted_at)}
                    <span :if={@brief.model_used}>| Model: {@brief.model_used}</span>
                  </p>
                </div>
                <Components.status_badge status="active" />
              </div>
              <p class="mt-2 text-sm whitespace-pre-wrap">
                {String.slice(@brief.content, 0, 300)}...
              </p>
            </div>
          </div>
          <div :if={!@brief} class="text-center py-8 text-base-content/70">
            No briefs yet
          </div>
        </div>
      </div>
      
    <!-- Drafts Tab -->
      <div :if={@active_tab == "drafts"} class="space-y-4">
        <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
          <div class="stat bg-base-200">
            <div class="stat-title">Draft</div>
            <div class="stat-value text-lg">
              {Enum.filter(@drafts, &(&1.status == "draft")) |> length}
            </div>
          </div>
          <div class="stat bg-base-200">
            <div class="stat-title">Ranked</div>
            <div class="stat-value text-lg">
              {Enum.filter(@drafts, &(&1.status == "ranked")) |> length}
            </div>
          </div>
          <div class="stat bg-base-200">
            <div class="stat-title">Approved</div>
            <div class="stat-value text-lg">
              {Enum.filter(@drafts, &(&1.status == "approved")) |> length}
            </div>
          </div>
        </div>

        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title">Draft Queue</h2>
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Platform</th>
                    <th>Type</th>
                    <th>Model</th>
                    <th>Status</th>
                    <th>Created</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={draft <- Enum.take(@drafts, 20)}>
                    <td>{draft.platform}</td>
                    <td>{draft.content_type}</td>
                    <td>{draft.generating_model}</td>
                    <td><Components.status_badge status={draft.status} /></td>
                    <td>{Components.format_datetime(draft.inserted_at)}</td>
                  </tr>
                </tbody>
              </table>
            </div>
            <div :if={length(@drafts) == 0} class="text-center py-4 text-base-content/70">
              No drafts yet
            </div>
          </div>
        </div>
      </div>
      
    <!-- History Tab -->
      <div :if={@active_tab == "history"} class="card bg-base-200">
        <div class="card-body">
          <h2 class="card-title">Publishing History</h2>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Platform</th>
                  <th>Post ID</th>
                  <th>Posted</th>
                  <th>URL</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={post <- @published_posts}>
                  <td>{post.platform}</td>
                  <td class="font-mono text-xs">
                    {String.slice(post.platform_post_id || "", 0, 20)}...
                  </td>
                  <td>{Components.format_datetime(post.posted_at)}</td>
                  <td>
                    <a
                      :if={post.platform_post_url}
                      href={post.platform_post_url}
                      target="_blank"
                      class="link link-primary text-xs"
                    >
                      View
                    </a>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <div :if={length(@published_posts) == 0} class="text-center py-4 text-base-content/70">
            No published posts yet
          </div>
        </div>
      </div>
    </div>
    """
  end
end
