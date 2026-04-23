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
    blocked_drafts = fetch_blocked_drafts(product_id)

    {:ok,
     assign(socket,
       products: products,
       product_filter: product_id,
       start_date: start_date,
       end_date: end_date,
       posts: posts,
       scheduled_drafts: scheduled_drafts,
       blocked_drafts: blocked_drafts,
       view: Map.get(params, "view", "timeline"),
       preview_draft: nil
     )}
  end

  @impl true
  def handle_event("filter_product", %{"product" => product_id}, socket) do
    {start_date, end_date} = {socket.assigns.start_date, socket.assigns.end_date}
    posts = fetch_posts(product_id, start_date, end_date)
    scheduled_drafts = fetch_scheduled_drafts(product_id)
    blocked_drafts = fetch_blocked_drafts(product_id)

    {:noreply,
     assign(socket,
       product_filter: product_id,
       posts: posts,
       scheduled_drafts: scheduled_drafts,
       blocked_drafts: blocked_drafts
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
  def handle_event("preview_draft", %{"draft-id" => draft_id}, socket) do
    case ContentGeneration.get_draft(draft_id) do
      nil -> {:noreply, put_flash(socket, :error, "Draft not found")}
      draft -> {:noreply, assign(socket, preview_draft: draft)}
    end
  end

  @impl true
  def handle_event("close_preview", _params, socket) do
    {:noreply, assign(socket, preview_draft: nil)}
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

  defp fetch_blocked_drafts(""), do: ContentGeneration.list_blocked_drafts(nil)
  defp fetch_blocked_drafts(product_id), do: ContentGeneration.list_blocked_drafts(product_id)

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
              <tr :for={post <- Enum.sort_by(@posts, & &1.posted_at, {:desc, DateTime})}>
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

        <h2 class="font-semibold mt-8">Blocked (Awaiting Image)</h2>
        <p class="text-sm text-base-content/70">
          Social posts blocked from publishing until an image is attached.
        </p>
        <div :if={length(@blocked_drafts) > 0} class="overflow-x-auto">
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>Created</th>
                <th>Platform</th>
                <th>Type</th>
                <th>Status</th>
                <th>Content</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={draft <- @blocked_drafts}>
                <td>{Components.format_datetime(draft.inserted_at)}</td>
                <td>
                  <span class="badge badge-sm badge-outline">{draft.platform}</span>
                </td>
                <td>{draft.content_type}</td>
                <td><Components.status_badge status={draft.status} /></td>
                <td class="max-w-xs truncate">{draft.content}</td>
              </tr>
            </tbody>
          </table>
        </div>
        <div :if={length(@blocked_drafts) == 0} class="text-center py-8 text-base-content/70">
          No blocked drafts
        </div>
      </div>
      
    <!-- Calendar View (week) -->
      <div :if={@view == "calendar"} class="card bg-base-200">
        <div class="card-body">
          <h2 class="card-title">Week</h2>
          <p class="text-sm text-base-content/70">
            Upcoming publishes by day + platform. Click any entry to preview the draft.
          </p>
          
    <!-- Desktop / tablet grid (md+) -->
          <div class="hidden md:grid grid-cols-7 gap-2" role="grid" aria-label="Week calendar">
            <div
              :for={day <- week_days(Date.utc_today())}
              data-week-day={Date.to_iso8601(day)}
              role="gridcell"
              class={[
                "border border-base-300 rounded p-2 min-h-40",
                today?(day) && "bg-base-300"
              ]}
            >
              <div class="text-xs font-semibold">
                {day_header(day)}
              </div>
              <ul class="mt-2 space-y-1">
                <li
                  :for={entry <- entries_for_day(@posts, @scheduled_drafts, day)}
                  class="text-xs"
                >
                  <button
                    type="button"
                    class="w-full text-left flex items-center gap-1 hover:bg-base-100 rounded px-1 py-0.5 focus:outline-none focus:ring focus:ring-primary"
                    phx-click="preview_draft"
                    phx-value-draft-id={entry.draft_id}
                    aria-label={"Preview draft on #{entry.platform} for #{Date.to_iso8601(day)}"}
                    data-week-entry={entry.draft_id}
                  >
                    <span aria-hidden="true">
                      <.icon name={platform_icon(entry.platform)} class="size-3 shrink-0" />
                    </span>
                    <span class="badge badge-xs badge-outline whitespace-nowrap">
                      {entry.platform}
                    </span>
                    <span class="truncate">{snippet(entry.content)}</span>
                  </button>
                </li>
                <li
                  :if={entries_for_day(@posts, @scheduled_drafts, day) == []}
                  class="text-xs text-base-content/40"
                >
                  —
                </li>
              </ul>
            </div>
          </div>
          
    <!-- Mobile stacked list (< md) -->
          <div class="md:hidden space-y-3" data-week-calendar-mobile>
            <section
              :for={day <- week_days(Date.utc_today())}
              data-week-day={Date.to_iso8601(day)}
              aria-label={"Publishes on #{Date.to_iso8601(day)}"}
              class={[
                "border border-base-300 rounded p-3",
                today?(day) && "bg-base-300"
              ]}
            >
              <h3 class="text-sm font-semibold">{day_header(day)}</h3>
              <ul class="mt-2 space-y-1">
                <li :for={entry <- entries_for_day(@posts, @scheduled_drafts, day)}>
                  <button
                    type="button"
                    class="w-full text-left flex items-center gap-2 px-2 py-1 rounded hover:bg-base-100 focus:outline-none focus:ring focus:ring-primary"
                    phx-click="preview_draft"
                    phx-value-draft-id={entry.draft_id}
                    aria-label={"Preview draft on #{entry.platform}"}
                  >
                    <span aria-hidden="true">
                      <.icon name={platform_icon(entry.platform)} class="size-4 shrink-0" />
                    </span>
                    <span class="badge badge-sm badge-outline whitespace-nowrap">
                      {entry.platform}
                    </span>
                    <span class="text-xs truncate flex-1">{snippet(entry.content)}</span>
                  </button>
                </li>
                <li
                  :if={entries_for_day(@posts, @scheduled_drafts, day) == []}
                  class="text-xs text-base-content/60"
                >
                  Nothing scheduled
                </li>
              </ul>
            </section>
          </div>
        </div>
      </div>
      
    <!-- Draft preview drawer -->
      <aside
        :if={@preview_draft}
        role="dialog"
        aria-modal="true"
        aria-label="Draft preview"
        data-draft-preview={@preview_draft.id}
        class="card bg-base-200"
      >
        <div class="card-body">
          <div class="flex justify-between items-start">
            <h2 class="card-title">Draft preview</h2>
            <button
              type="button"
              class="btn btn-ghost btn-sm btn-circle"
              phx-click="close_preview"
              aria-label="Close preview"
            >
              <.icon name="hero-x" class="size-4" />
            </button>
          </div>
          <div class="text-xs text-base-content/70">
            <span class="badge badge-outline">{@preview_draft.platform}</span>
            <span>{@preview_draft.content_type}</span>
            <Components.status_badge status={@preview_draft.status} />
          </div>
          <p class="whitespace-pre-wrap text-sm mt-2">{@preview_draft.content}</p>
          <p :if={@preview_draft.image_url} class="text-xs text-base-content/70 mt-2">
            Image: {@preview_draft.image_url}
          </p>
        </div>
      </aside>
    </div>
    """
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

  # --- week-view helpers --------------------------------------------------

  # Seven days starting from the Sunday on or before `anchor`.
  defp week_days(%Date{} = anchor) do
    dow = Date.day_of_week(anchor, :sunday)
    start = Date.add(anchor, -(dow - 1))
    Enum.map(0..6, &Date.add(start, &1))
  end

  defp today?(%Date{} = d), do: Date.compare(d, Date.utc_today()) == :eq

  @dow_short ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

  defp day_header(%Date{} = d) do
    idx = Date.day_of_week(d, :sunday) - 1
    "#{Enum.at(@dow_short, idx)} #{d.month}/#{d.day}"
  end

  # Published-post entries keyed on `posted_at` date; approved drafts
  # collapse to "today" since we don't have per-draft scheduled_at on
  # the Draft schema yet.
  defp entries_for_day(posts, scheduled_drafts, %Date{} = day) do
    published_entries =
      posts
      |> Enum.filter(fn p -> post_on_day?(p, day) end)
      |> Enum.map(&post_entry/1)

    scheduled_entries =
      if today?(day) do
        Enum.map(scheduled_drafts, &draft_entry/1)
      else
        []
      end

    published_entries ++ scheduled_entries
  end

  defp post_on_day?(post, day) do
    case post.posted_at do
      %DateTime{} = dt ->
        Date.compare(Date.new!(dt.year, dt.month, dt.day), day) == :eq

      _ ->
        false
    end
  end

  defp post_entry(post) do
    %{
      draft_id: post.draft_id,
      platform: post.platform,
      content: post_content(post)
    }
  end

  defp draft_entry(draft) do
    %{draft_id: draft.id, platform: draft.platform, content: draft.content}
  end

  defp post_content(post) do
    post.platform_post_url || post.platform_post_id || ""
  end

  defp snippet(nil), do: ""

  defp snippet(text) when is_binary(text) do
    text |> String.slice(0, 60)
  end

  defp platform_icon("twitter"), do: "hero-hashtag"
  defp platform_icon("linkedin"), do: "hero-briefcase"
  defp platform_icon("reddit"), do: "hero-chat-bubble-bottom-center"
  defp platform_icon("facebook"), do: "hero-user-group"
  defp platform_icon("instagram"), do: "hero-camera"
  defp platform_icon("blog"), do: "hero-document-text"
  defp platform_icon("youtube"), do: "hero-play"
  defp platform_icon(_), do: "hero-megaphone"
end
