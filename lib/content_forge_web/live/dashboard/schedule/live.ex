defmodule ContentForgeWeb.Live.Dashboard.Schedule.Live do
  @moduledoc """
  LiveView for schedule view with calendar/timeline of upcoming and past posts.
  """
  use ContentForgeWeb, :live_view
  alias ContentForge.Publishing
  alias ContentForge.Products
  alias ContentForge.ContentGeneration
  alias ContentForgeWeb.Live.Dashboard.Components

  @impl true
  def mount(params, _session, socket) do
    products = Products.list_products()
    product_id = Map.get(params, "product", "")

    {start_date, end_date} = get_date_range(params)

    posts = fetch_posts(product_id, start_date, end_date)
    scheduled_drafts = fetch_scheduled_drafts(product_id)

    {:ok,
     assign(socket,
       products: products,
       product_filter: product_id,
       start_date: start_date,
       end_date: end_date,
       posts: posts,
       scheduled_drafts: scheduled_drafts,
       view: Map.get(params, "view", "timeline")
     )}
  end

  @impl true
  def handle_event("filter_product", %{"product" => product_id}, socket) do
    {start_date, end_date} = {socket.assigns.start_date, socket.assigns.end_date}
    posts = fetch_posts(product_id, start_date, end_date)
    scheduled_drafts = fetch_scheduled_drafts(product_id)

    {:noreply,
     assign(socket,
       product_filter: product_id,
       posts: posts,
       scheduled_drafts: scheduled_drafts
     )}
  end

  @impl true
  def handle_event("switch_view", %{"view" => view}, socket) do
    {:noreply, assign(socket, view: view)}
  end

  @impl true
  def handle_event("navigate_dates", %{"direction" => direction}, socket) do
    shift_days =
      case direction do
        "prev" -> -7
        "next" -> 7
        _ -> 0
      end

    start_date = Date.add(socket.assigns.start_date, shift_days)
    end_date = Date.add(socket.assigns.end_date, shift_days)

    posts = fetch_posts(socket.assigns.product_filter, start_date, end_date)

    {:noreply,
     assign(socket,
       start_date: start_date,
       end_date: end_date,
       posts: posts
     )}
  end

  @impl true
  def handle_event("today", _params, socket) do
    today = Date.utc_today()
    start_date = Date.add(today, -7)
    end_date = Date.add(today, 14)

    posts = fetch_posts(socket.assigns.product_filter, start_date, end_date)

    {:noreply,
     assign(socket,
       start_date: start_date,
       end_date: end_date,
       posts: posts
     )}
  end

  defp get_date_range(params) do
    today = Date.utc_today()

    case Map.get(params, "range") do
      "week" ->
        {Date.add(today, -7), Date.add(today, 14)}

      "month" ->
        {Date.add(today, -30), Date.add(today, 30)}

      _ ->
        {Date.add(today, -7), Date.add(today, 14)}
    end
  end

  defp fetch_posts("", start_date, end_date) do
    Publishing.list_published_posts(limit: 100)
    |> Enum.filter(fn post ->
      case post.posted_at do
        nil ->
          false

        dt ->
          dt >= DateTime.new!(start_date, ~T[00:00:00]) and
            dt <= DateTime.new!(end_date, ~T[23:59:59])
      end
    end)
  end

  defp fetch_posts(product_id, _start_date, _end_date) do
    Publishing.list_published_posts(product_id: product_id, limit: 100)
  end

  defp fetch_scheduled_drafts("") do
    ContentGeneration.list_approved_drafts(nil)
  end

  defp fetch_scheduled_drafts(product_id) do
    ContentGeneration.list_approved_drafts(product_id)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
        <div>
          <h1 class="text-2xl font-bold">Schedule</h1>
          <p class="text-base-content/70">Calendar and timeline of posts</p>
        </div>
        <div class="flex gap-2">
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
      </div>
      
    <!-- Date Navigation -->
      <div class="flex items-center justify-between">
        <div class="flex gap-2">
          <button class="btn btn-ghost btn-sm" phx-click="navigate_dates" phx-value-direction="prev">
            <.icon name="hero-chevron-left" class="size-4" />
          </button>
          <button class="btn btn-ghost btn-sm" phx-click="today">Today</button>
          <button class="btn btn-ghost btn-sm" phx-click="navigate_dates" phx-value-direction="next">
            <.icon name="hero-chevron-right" class="size-4" />
          </button>
        </div>
        <div class="text-sm">
          {format_short_date(@start_date)} - {format_date(@end_date)}
        </div>
        <div class="tabs tabs-boxed tabs-sm">
          <button
            class={["tab", @view == "timeline" && "tab-active"]}
            phx-click="switch_view"
            phx-value-view="timeline"
          >
            Timeline
          </button>
          <button
            class={["tab", @view == "calendar" && "tab-active"]}
            phx-click="switch_view"
            phx-value-view="calendar"
          >
            Calendar
          </button>
        </div>
      </div>
      
    <!-- Stats -->
      <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
        <div class="stat bg-base-200">
          <div class="stat-title">Published</div>
          <div class="stat-value">{length(@posts)}</div>
        </div>
        <div class="stat bg-base-200">
          <div class="stat-title">Scheduled</div>
          <div class="stat-value">{length(@scheduled_drafts)}</div>
        </div>
        <div class="stat bg-base-200">
          <div class="stat-title">Twitter</div>
          <div class="stat-value">{Enum.filter(@posts, &(&1.platform == "twitter")) |> length}</div>
        </div>
        <div class="stat bg-base-200">
          <div class="stat-title">LinkedIn</div>
          <div class="stat-value">{Enum.filter(@posts, &(&1.platform == "linkedin")) |> length}</div>
        </div>
      </div>
      
    <!-- Timeline View -->
      <div :if={@view == "timeline"} class="space-y-4">
        <h2 class="font-semibold">Past Posts</h2>
        <div class="overflow-x-auto">
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>Date</th>
                <th>Platform</th>
                <th>Post ID</th>
                <th>Engagement</th>
                <th>Link</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={post <- Enum.sort_by(@posts, & &1.posted_at, {:desc, nil})}>
                <td>{Components.format_datetime(post.posted_at)}</td>
                <td>
                  <span class="badge badge-sm badge-outline">{post.platform}</span>
                </td>
                <td class="font-mono text-xs">
                  {String.slice(post.platform_post_id || "", 0, 15)}...
                </td>
                <td>
                  <span :if={post.engagement_data}>
                    {(post.engagement_data["likes"] || 0) + (post.engagement_data["comments"] || 0) +
                      (post.engagement_data["shares"] || 0)}
                  </span>
                  <span :if={!post.engagement_data}>—</span>
                </td>
                <td>
                  <a
                    :if={post.platform_post_url}
                    href={post.platform_post_url}
                    target="_blank"
                    class="link link-primary link-sm"
                  >
                    View
                  </a>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={length(@posts) == 0} class="text-center py-8 text-base-content/70">
          No published posts in this period
        </div>

        <h2 class="font-semibold mt-8">Scheduled (Ready to Publish)</h2>
        <div class="overflow-x-auto">
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>Created</th>
                <th>Platform</th>
                <th>Type</th>
                <th>Content</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={draft <- @scheduled_drafts}>
                <td>{Components.format_datetime(draft.inserted_at)}</td>
                <td>
                  <span class="badge badge-sm badge-outline">{draft.platform}</span>
                </td>
                <td>{draft.content_type}</td>
                <td class="max-w-xs truncate">{draft.content}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={length(@scheduled_drafts) == 0} class="text-center py-8 text-base-content/70">
          No scheduled drafts
        </div>
      </div>
      
    <!-- Calendar View -->
      <div :if={@view == "calendar"} class="card bg-base-200">
        <div class="card-body">
          <h2 class="card-title">Calendar</h2>
          <div class="grid grid-cols-7 gap-1 text-center text-sm">
            <div class="font-semibold p-2">Sun</div>
            <div class="font-semibold p-2">Mon</div>
            <div class="font-semibold p-2">Tue</div>
            <div class="font-semibold p-2">Wed</div>
            <div class="font-semibold p-2">Thu</div>
            <div class="font-semibold p-2">Fri</div>
            <div class="font-semibold p-2">Sat</div>

            <%= for day <- days_in_range(@start_date, @end_date) do %>
              <div class={[
                "p-2 min-h-20 border border-base-300 rounded",
                Date.compare(day, Date.utc_today()) == :eq && "bg-base-300",
                Date.compare(day, Date.utc_today()) == :lt && "opacity-50"
              ]}>
                <div class="font-semibold text-xs">{day.day}</div>
                <div class="space-y-1 mt-1">
                  <div :for={post <- posts_for_day(@posts, day)} class="text-xs truncate">
                    <span class="badge badge-xs badge-primary">{post.platform}</span>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp days_in_range(start_date, end_date) do
    days = Date.diff(end_date, start_date) + 1
    Enum.map(0..(days - 1), fn i -> Date.add(start_date, i) end)
  end

  defp format_short_date(%Date{} = date) do
    month_name = [
      "Jan",
      "Feb",
      "Mar",
      "Apr",
      "May",
      "Jun",
      "Jul",
      "Aug",
      "Sep",
      "Oct",
      "Nov",
      "Dec"
    ]

    "#{Enum.at(month_name, date.month - 1)} #{date.day}"
  end

  defp format_date(%Date{} = date) do
    month_name = [
      "Jan",
      "Feb",
      "Mar",
      "Apr",
      "May",
      "Jun",
      "Jul",
      "Aug",
      "Sep",
      "Oct",
      "Nov",
      "Dec"
    ]

    "#{Enum.at(month_name, date.month - 1)} #{date.day}, #{date.year}"
  end

  defp posts_for_day(posts, day) do
    Enum.filter(posts, fn post ->
      case post.posted_at do
        nil -> false
        dt -> Date.compare(Date.new!(dt.year, dt.month, dt.day), day) == :eq
      end
    end)
  end
end
