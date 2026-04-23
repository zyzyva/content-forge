defmodule ContentForgeWeb.Live.Dashboard.Products.DetailLive do
  require Logger

  @moduledoc """
  LiveView for per-product details: snapshot status, brief, draft queue, publishing history.
  """
  use ContentForgeWeb, :live_view
  alias ContentForge.ContentGeneration
  alias ContentForge.Jobs.AssetBundleDraftGenerator
  alias ContentForge.Jobs.AssetImageProcessor
  alias ContentForge.Jobs.AssetVideoProcessor
  alias ContentForge.ProductAssets
  alias ContentForge.ProductAssets.AssetBundle
  alias ContentForge.ProductAssets.ProductAsset
  alias ContentForge.Products
  alias ContentForge.Publishing
  alias ContentForgeWeb.Live.Dashboard.Components

  @bundle_generation_platforms ~w(twitter linkedin reddit facebook instagram)
  @default_variants_per_platform 3

  # MIME types used for `allow_upload :accept`. Using mime types rather than
  # extensions so unusual ones (.heic, .m4v) do not require extending the
  # Mime library at compile time. The HTML <input accept> string on the
  # form uses the broader "image/*,video/*" so mobile browsers reliably
  # open camera capture / camera roll.
  @upload_accept_mimes ~w(
    image/jpeg image/png image/webp image/heic
    video/mp4 video/quicktime video/x-m4v
  )
  @video_byte_cap 500 * 1_024 * 1_024
  @presign_expires_seconds 900

  @impl true
  def mount(%{"id" => product_id}, _session, socket) do
    product = Products.get_product!(product_id)

    snapshots = Products.list_product_snapshots_for_product(product_id)
    brief = ContentGeneration.get_latest_content_brief_for_product(product_id)
    drafts = ContentGeneration.list_drafts_for_product(product_id)
    published_posts = Publishing.list_published_posts(product_id: product_id, limit: 10)
    assets = ProductAssets.list_assets(product_id)
    bundles = list_bundles_with_assets(product_id)

    if connected?(socket) do
      ProductAssets.subscribe(product_id)
      ProductAssets.subscribe_bundles(product_id)
    end

    {:ok,
     socket
     |> assign(
       product: product,
       snapshots: snapshots,
       brief: brief,
       drafts: drafts,
       published_posts: published_posts,
       assets: assets,
       asset_search: "",
       asset_media_filter: "",
       asset_tag_catalog: ProductAssets.list_distinct_tags(product_id),
       asset_top_tags: ProductAssets.top_tags(product_id, 8),
       bundles: bundles,
       bundle_form: to_bundle_form(%AssetBundle{}, %{}),
       open_bundle_id: nil,
       picker_media_filter: "",
       generating_bundle_ids: MapSet.new(),
       bundle_generation_error: nil,
       active_tab: "overview"
     )
     |> allow_upload(:assets,
       accept: @upload_accept_mimes,
       max_entries: 10,
       max_file_size: @video_byte_cap,
       external: &presign_asset_upload/2
     )}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: tab)}
  end

  @impl true
  def handle_event("validate_uploads", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :assets, ref)}
  end

  @impl true
  def handle_event("save_uploads", _params, socket) do
    created =
      consume_uploaded_entries(socket, :assets, fn meta, entry ->
        register_uploaded_asset(socket.assigns.product, meta, entry)
      end)

    socket =
      socket
      |> refresh_assets()
      |> put_flash(:info, "#{length(created)} asset(s) registered")

    {:noreply, socket}
  end

  @impl true
  def handle_event("search_assets", %{"value" => search}, socket) do
    {:noreply, socket |> assign(asset_search: search) |> refresh_assets()}
  end

  def handle_event("search_assets", %{"search" => search}, socket) do
    {:noreply, socket |> assign(asset_search: search) |> refresh_assets()}
  end

  @impl true
  def handle_event("filter_media_type", %{"media_type" => media_type}, socket) do
    {:noreply, socket |> assign(asset_media_filter: media_type) |> refresh_assets()}
  end

  @impl true
  def handle_event("use_facet", %{"tag" => tag}, socket) do
    {:noreply, socket |> assign(asset_search: tag) |> refresh_assets()}
  end

  @impl true
  def handle_event("add_tag", %{"asset-id" => asset_id, "tag" => tag}, socket) do
    asset = ProductAssets.get_asset!(asset_id)
    {:ok, _} = ProductAssets.add_tag(asset, tag)
    # Refresh synchronously so this session sees the change immediately;
    # the PubSub broadcast from add_tag/2 keeps other subscribers in sync.
    {:noreply, socket |> refresh_assets() |> refresh_asset_catalog()}
  end

  @impl true
  def handle_event("remove_tag", %{"asset-id" => asset_id, "tag" => tag}, socket) do
    asset = ProductAssets.get_asset!(asset_id)
    {:ok, _} = ProductAssets.remove_tag(asset, tag)
    {:noreply, socket |> refresh_assets() |> refresh_asset_catalog()}
  end

  # --- bundle events ------------------------------------------------------

  @impl true
  def handle_event("create_bundle", %{"bundle" => params}, socket) do
    attrs = Map.put(params, "product_id", socket.assigns.product.id)

    case ProductAssets.create_bundle(attrs) do
      {:ok, _bundle} ->
        {:noreply,
         socket
         |> assign(bundle_form: to_bundle_form(%AssetBundle{}, %{}))
         |> refresh_bundles()}

      {:error, changeset} ->
        {:noreply, assign(socket, bundle_form: to_form(changeset, as: :bundle))}
    end
  end

  @impl true
  def handle_event("open_bundle", %{"bundle-id" => bundle_id}, socket) do
    {:noreply, assign(socket, open_bundle_id: bundle_id, picker_media_filter: "")}
  end

  @impl true
  def handle_event("close_bundle", _params, socket) do
    {:noreply, assign(socket, open_bundle_id: nil)}
  end

  @impl true
  def handle_event(
        "remove_bundle_asset",
        %{"bundle-id" => bundle_id, "asset-id" => asset_id},
        socket
      ) do
    bundle = ProductAssets.get_bundle!(bundle_id)
    asset = ProductAssets.get_asset!(asset_id)
    :ok = ProductAssets.remove_asset_from_bundle(bundle, asset)
    {:noreply, refresh_bundles(socket)}
  end

  @impl true
  def handle_event(
        "reorder_bundle_asset",
        %{"bundle-id" => bundle_id, "asset-id" => asset_id, "direction" => direction},
        socket
      ) do
    bundle = ProductAssets.get_bundle!(bundle_id)
    current_ids = Enum.map(bundle.bundle_assets, & &1.asset_id)
    new_ids = shift_asset(current_ids, asset_id, direction)
    {:ok, _} = ProductAssets.reorder_bundle_assets(bundle, new_ids)
    {:noreply, refresh_bundles(socket)}
  end

  @impl true
  def handle_event(
        "filter_picker_media",
        %{"bundle-id" => bundle_id, "media_type" => media_type},
        socket
      ) do
    {:noreply, assign(socket, open_bundle_id: bundle_id, picker_media_filter: media_type)}
  end

  @impl true
  def handle_event(
        "add_bundle_asset",
        %{"bundle-id" => bundle_id, "asset-id" => asset_id},
        socket
      ) do
    bundle = ProductAssets.get_bundle!(bundle_id)
    asset = ProductAssets.get_asset!(asset_id)
    {:ok, _} = ProductAssets.add_asset_to_bundle(bundle, asset)
    {:noreply, refresh_bundles(socket)}
  end

  @impl true
  def handle_event("archive_bundle", %{"bundle-id" => bundle_id}, socket) do
    bundle = ProductAssets.get_bundle!(bundle_id)
    {:ok, _} = ProductAssets.archive_bundle(bundle)

    {:noreply,
     socket
     |> assign(open_bundle_id: nil)
     |> refresh_bundles()}
  end

  @impl true
  def handle_event("soft_delete_bundle", %{"bundle-id" => bundle_id}, socket) do
    bundle = ProductAssets.get_bundle!(bundle_id)
    {:ok, _} = ProductAssets.soft_delete_bundle(bundle)

    {:noreply,
     socket
     |> assign(open_bundle_id: nil)
     |> refresh_bundles()}
  end

  @impl true
  def handle_event("generate_drafts", %{"bundle-id" => bundle_id} = params, socket) do
    platforms = normalize_platforms(params["platforms"])
    variants = parse_variants(params["variants_per_platform"])

    dispatch_generation(platforms, variants, bundle_id, socket)
  end

  @impl true
  def handle_info({event, asset}, socket)
      when event in [:asset_created, :asset_updated, :asset_deleted] do
    socket =
      socket
      |> refresh_assets()
      |> refresh_asset_catalog()
      |> assign(last_asset_event: {event, asset.id})

    {:noreply, socket}
  end

  @impl true
  def handle_info({event, %AssetBundle{}}, socket)
      when event in [
             :bundle_created,
             :bundle_updated,
             :bundle_archived,
             :bundle_deleted,
             :bundle_membership_changed
           ] do
    {:noreply, refresh_bundles(socket)}
  end

  @impl true
  def handle_info({:bundle_generation_started, bundle_id}, socket) do
    {:noreply, mark_generating(socket, bundle_id)}
  end

  @impl true
  def handle_info({:bundle_generation_finished, bundle_id}, socket) do
    {:noreply, unmark_generating(socket, bundle_id)}
  end

  # --- filter application --------------------------------------------------

  defp refresh_assets(socket) do
    assigns = socket.assigns

    opts =
      []
      |> maybe_put_opt(:search, blank_to_nil(assigns[:asset_search]))
      |> maybe_put_opt(:media_type, blank_to_nil(assigns[:asset_media_filter]))

    assign(socket, assets: ProductAssets.list_assets(assigns.product.id, opts))
  end

  defp refresh_asset_catalog(socket) do
    product_id = socket.assigns.product.id

    assign(socket,
      asset_tag_catalog: ProductAssets.list_distinct_tags(product_id),
      asset_top_tags: ProductAssets.top_tags(product_id, 8)
    )
  end

  defp refresh_bundles(socket) do
    assign(socket, bundles: list_bundles_with_assets(socket.assigns.product.id))
  end

  # --- bundle generation helpers ------------------------------------------

  defp dispatch_generation([], _variants, _bundle_id, socket) do
    {:noreply, assign(socket, bundle_generation_error: "Select at least one platform.")}
  end

  defp dispatch_generation(platforms, variants, bundle_id, socket) do
    bundle = ProductAssets.get_bundle!(bundle_id)

    {:ok, _job} =
      AssetBundleDraftGenerator.new(%{
        "bundle_id" => bundle.id,
        "platforms" => platforms,
        "variants_per_platform" => variants
      })
      |> Oban.insert()

    :ok =
      ProductAssets.broadcast_bundle_generation_started(bundle.product_id, bundle.id)

    {:noreply,
     socket
     |> assign(bundle_generation_error: nil)
     |> mark_generating(bundle.id)}
  end

  defp normalize_platforms(nil), do: []
  defp normalize_platforms(""), do: []

  defp normalize_platforms(list) when is_list(list) do
    list
    |> Enum.filter(&(is_binary(&1) and &1 in @bundle_generation_platforms))
    |> Enum.uniq()
  end

  defp normalize_platforms(_), do: []

  defp parse_variants(nil), do: @default_variants_per_platform
  defp parse_variants(""), do: @default_variants_per_platform

  defp parse_variants(value) when is_integer(value) and value > 0, do: value

  defp parse_variants(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> n
      _ -> @default_variants_per_platform
    end
  end

  defp parse_variants(_), do: @default_variants_per_platform

  defp mark_generating(socket, bundle_id) do
    assign(socket,
      generating_bundle_ids: MapSet.put(socket.assigns.generating_bundle_ids, bundle_id)
    )
  end

  defp unmark_generating(socket, bundle_id) do
    assign(socket,
      generating_bundle_ids: MapSet.delete(socket.assigns.generating_bundle_ids, bundle_id)
    )
  end

  defp enabled_platforms(%Products.Product{publishing_targets: targets}),
    do: enabled_platforms(targets)

  defp enabled_platforms(nil), do: []

  defp enabled_platforms(%{} = targets) do
    @bundle_generation_platforms
    |> Enum.filter(fn platform ->
      case Map.get(targets, platform) do
        %{"enabled" => true} -> true
        _ -> false
      end
    end)
  end

  defp enabled_platforms(_), do: []

  defp list_bundles_with_assets(product_id) do
    product_id
    |> ProductAssets.list_bundles()
    |> Enum.map(&ProductAssets.get_bundle!(&1.id))
  end

  defp to_bundle_form(bundle, attrs),
    do: bundle |> AssetBundle.changeset(attrs) |> to_form(as: :bundle)

  # Shifts `asset_id` one slot earlier or later in `ids`. No-op if the
  # asset is already at the edge or not present in the list.
  defp shift_asset(ids, asset_id, "up") do
    case Enum.find_index(ids, &(&1 == asset_id)) do
      nil -> ids
      0 -> ids
      idx -> swap(ids, idx, idx - 1)
    end
  end

  defp shift_asset(ids, asset_id, "down") do
    last = length(ids) - 1

    case Enum.find_index(ids, &(&1 == asset_id)) do
      nil -> ids
      ^last -> ids
      idx -> swap(ids, idx, idx + 1)
    end
  end

  defp swap(list, i, j) do
    a = Enum.at(list, i)
    b = Enum.at(list, j)

    list
    |> List.replace_at(i, b)
    |> List.replace_at(j, a)
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # --- external upload presigning -----------------------------------------

  defp presign_asset_upload(entry, socket) do
    product_id = socket.assigns.product.id
    storage_key = build_storage_key(product_id, entry.client_name)

    case storage_impl().presigned_put_url(storage_key, entry.client_type,
           expires_in: @presign_expires_seconds
         ) do
      {:ok, url} ->
        meta = %{
          uploader: "S3",
          url: url,
          storage_key: storage_key,
          content_type: entry.client_type
        }

        {:ok, meta, socket}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp storage_impl do
    Application.get_env(:content_forge, :asset_storage_impl, ContentForge.Storage)
  end

  defp build_storage_key(product_id, filename) do
    safe =
      filename
      |> Path.basename()
      |> String.replace(~r/[^A-Za-z0-9._-]/, "_")

    "products/#{product_id}/assets/#{Ecto.UUID.generate()}/#{safe}"
  end

  defp register_uploaded_asset(product, meta, entry) do
    attrs = %{
      product_id: product.id,
      storage_key: meta.storage_key,
      filename: entry.client_name,
      mime_type: entry.client_type,
      media_type: media_type_for(entry.client_type),
      byte_size: entry.client_size,
      uploaded_at: DateTime.utc_now(),
      tags: []
    }

    case ProductAssets.create_asset(attrs) do
      {:ok, asset} ->
        enqueue_processing(asset)
        {:ok, asset}

      {:error, _changeset} = err ->
        err
    end
  end

  defp media_type_for("image/" <> _), do: "image"
  defp media_type_for("video/" <> _), do: "video"

  defp enqueue_processing(%ProductAsset{media_type: "image", id: id}) do
    %{"asset_id" => id} |> AssetImageProcessor.new() |> Oban.insert()
  end

  defp enqueue_processing(%ProductAsset{media_type: "video", id: id}) do
    %{"asset_id" => id} |> AssetVideoProcessor.new() |> Oban.insert()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main-content" aria-labelledby="page-title" class="space-y-6">
      <header class="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
        <div>
          <div class="flex items-center gap-2">
            <.link
              navigate={~p"/dashboard/products"}
              class="btn btn-ghost btn-sm"
              aria-label="Back to products list"
            >
              <span aria-hidden="true">
                <.icon name="hero-arrow-left" class="size-4" />
              </span>
            </.link>
            <h1 id="page-title" class="text-2xl font-bold">{@product.name}</h1>
          </div>
          <p class="text-base-content/70 ml-8">
            Voice: {@product.voice_profile}
          </p>
        </div>
      </header>
      
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
        <button
          role="tab"
          class={["tab", @active_tab == "assets" && "tab-active"]}
          phx-click="switch_tab"
          phx-value-tab="assets"
        >
          Assets
        </button>
        <button
          role="tab"
          class={["tab", @active_tab == "bundles" && "tab-active"]}
          phx-click="switch_tab"
          phx-value-tab="bundles"
        >
          Bundles
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
      
    <!-- Assets Tab -->
      <div :if={@active_tab == "assets"} class="space-y-4">
        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title">Upload Assets</h2>
            <p class="text-sm text-base-content/70">
              Upload product images or short videos. Files upload directly to R2 via
              a presigned URL; metadata lives in Content Forge.
            </p>

            <form
              id="asset-upload-form"
              phx-change="validate_uploads"
              phx-submit="save_uploads"
              class="space-y-3"
            >
              <label class="form-control w-full" for={@uploads.assets.ref}>
                <span class="label-text">Files</span>
                <.live_file_input
                  upload={@uploads.assets}
                  accept="image/*,video/*"
                  class="file-input file-input-bordered w-full min-h-12"
                  aria-label="Product asset upload"
                />
              </label>

              <div :for={entry <- @uploads.assets.entries} class="card bg-base-100">
                <div class="card-body p-3">
                  <div class="flex justify-between items-center gap-2">
                    <div class="flex-1 min-w-0">
                      <p class="text-sm font-semibold truncate">{entry.client_name}</p>
                      <p class="text-xs text-base-content/70">
                        {entry.client_type} - {format_bytes(entry.client_size)}
                      </p>
                    </div>
                    <div class="flex items-center gap-2">
                      <div class="text-sm font-mono">{entry.progress}%</div>
                      <button
                        type="button"
                        class="btn btn-ghost btn-xs"
                        phx-click="cancel_upload"
                        phx-value-ref={entry.ref}
                        aria-label="Cancel upload"
                      >
                        <.icon name="hero-x" class="size-4" />
                      </button>
                    </div>
                  </div>
                  <progress
                    class="progress progress-primary w-full mt-1"
                    value={entry.progress}
                    max="100"
                  />
                  <p
                    :for={err <- upload_errors(@uploads.assets, entry)}
                    class="text-xs text-error mt-1"
                  >
                    {error_to_string(err)}
                  </p>
                </div>
              </div>

              <p :for={err <- upload_errors(@uploads.assets)} class="text-xs text-error">
                {error_to_string(err)}
              </p>

              <div class="flex justify-end">
                <button
                  type="submit"
                  class="btn btn-primary"
                  disabled={@uploads.assets.entries == []}
                >
                  Register uploads
                </button>
              </div>
            </form>
          </div>
        </div>

        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title">Assets</h2>

            <form
              phx-change="search_assets"
              phx-submit="search_assets"
              class="flex flex-col sm:flex-row gap-2"
              role="search"
            >
              <input
                type="search"
                name="search"
                value={@asset_search}
                placeholder="Search tags or description"
                aria-label="Search assets"
                class="input input-bordered w-full"
              />
              <select
                name="media_type"
                phx-change="filter_media_type"
                class="select select-bordered"
                aria-label="Filter by media type"
              >
                <option value="" selected={@asset_media_filter == ""}>All media</option>
                <option value="image" selected={@asset_media_filter == "image"}>Images</option>
                <option value="video" selected={@asset_media_filter == "video"}>Videos</option>
              </select>
            </form>

            <div :if={@asset_top_tags != []} class="flex flex-wrap gap-2 items-center">
              <span class="text-xs text-base-content/70">Top tags:</span>
              <button
                :for={{tag, count} <- @asset_top_tags}
                type="button"
                phx-click="use_facet"
                phx-value-tag={tag}
                class="badge badge-outline badge-sm hover:badge-primary cursor-pointer"
              >
                {tag} ({count})
              </button>
            </div>

            <datalist id="asset-tag-catalog">
              <option :for={tag <- @asset_tag_catalog} value={tag} />
            </datalist>

            <div :if={@assets == []} class="text-center py-8 text-base-content/70">
              No assets match
            </div>
            <div :if={@assets != []} class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Filename</th>
                    <th>Type</th>
                    <th>Size</th>
                    <th>Tags</th>
                    <th>Status</th>
                    <th>Uploaded</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={asset <- @assets}
                    id={"asset-#{asset.id}"}
                    data-asset-status={asset.status}
                  >
                    <td class="max-w-xs truncate">{asset.filename}</td>
                    <td>{asset.media_type}</td>
                    <td>{format_bytes(asset.byte_size)}</td>
                    <td>
                      <div class="flex flex-wrap gap-1 items-center">
                        <span
                          :for={tag <- asset.tags}
                          class="badge badge-sm gap-1"
                          data-asset-tag={tag}
                        >
                          {tag}
                          <button
                            type="button"
                            class="text-xs hover:text-error"
                            phx-click="remove_tag"
                            phx-value-asset-id={asset.id}
                            phx-value-tag={tag}
                            aria-label={"Remove tag #{tag}"}
                          >
                            ×
                          </button>
                        </span>
                        <form
                          phx-submit="add_tag"
                          class="inline-flex"
                          id={"add-tag-#{asset.id}"}
                        >
                          <input type="hidden" name="asset-id" value={asset.id} />
                          <input
                            type="text"
                            name="tag"
                            list="asset-tag-catalog"
                            placeholder="+ tag"
                            class="input input-xs input-bordered w-20"
                            aria-label={"Add tag to #{asset.filename}"}
                          />
                        </form>
                      </div>
                    </td>
                    <td>
                      <Components.status_badge status={asset.status} />
                      <span
                        :if={asset.status == "failed" && asset.error}
                        class="text-xs text-error ml-1"
                      >
                        {asset.error}
                      </span>
                    </td>
                    <td>{Components.format_datetime(asset.uploaded_at)}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </div>
      
    <!-- Bundles Tab -->
      <div :if={@active_tab == "bundles"} class="space-y-4">
        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title">Asset Bundles</h2>
            <p class="text-sm text-base-content/70">
              Group assets into named bundles for draft generation and publishing.
            </p>

            <.form
              :let={f}
              for={@bundle_form}
              as={:bundle}
              phx-submit="create_bundle"
              class="space-y-2"
            >
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
                <label class="form-control w-full">
                  <span class="label-text">Name</span>
                  <input
                    type="text"
                    name={f[:name].name}
                    value={Phoenix.HTML.Form.normalize_value("text", f[:name].value)}
                    placeholder="Johnson kitchen remodel"
                    class="input input-bordered w-full"
                    aria-label="Bundle name"
                  />
                  <span
                    :for={msg <- Enum.map(f[:name].errors, &translate_bundle_error/1)}
                    class="text-xs text-error mt-1"
                  >
                    {msg}
                  </span>
                </label>
                <label class="form-control w-full">
                  <span class="label-text">Context (optional)</span>
                  <input
                    type="text"
                    name={f[:context].name}
                    value={Phoenix.HTML.Form.normalize_value("text", f[:context].value)}
                    placeholder="3 weeks, quartz counters, custom cabinets"
                    class="input input-bordered w-full"
                    aria-label="Bundle context"
                  />
                </label>
              </div>
              <div class="flex justify-end">
                <button type="submit" class="btn btn-primary">Create bundle</button>
              </div>
            </.form>
          </div>
        </div>

        <div :if={@bundles == []} class="text-center py-8 text-base-content/70">
          No bundles yet
        </div>

        <div :if={@bundles != []} class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div
            :for={bundle <- @bundles}
            id={"bundle-#{bundle.id}"}
            class="card bg-base-200"
          >
            <div class="card-body">
              <div class="flex justify-between items-start gap-2">
                <div class="min-w-0">
                  <h3 class="card-title text-lg truncate">{bundle.name}</h3>
                  <p :if={bundle.context} class="text-xs text-base-content/70 truncate">
                    {bundle.context}
                  </p>
                </div>
                <div class="text-sm text-base-content/70 whitespace-nowrap">
                  {length(bundle.bundle_assets)} assets
                </div>
              </div>
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-1 mt-2">
                <div
                  :for={ba <- Enum.take(bundle.bundle_assets, 4)}
                  data-bundle-thumb={ba.asset_id}
                  class="aspect-square bg-base-300 rounded flex items-center justify-center text-xs text-base-content/60 overflow-hidden p-1 text-center"
                  title={ba.asset.filename}
                >
                  {ba.asset.filename}
                </div>
              </div>
              <div class="card-actions justify-end flex-wrap gap-1 mt-2">
                <button
                  :if={@open_bundle_id != bundle.id}
                  type="button"
                  class="btn btn-sm btn-ghost"
                  phx-click="open_bundle"
                  phx-value-bundle-id={bundle.id}
                  aria-label={"Open bundle #{bundle.name}"}
                >
                  Open
                </button>
                <button
                  :if={@open_bundle_id == bundle.id}
                  type="button"
                  class="btn btn-sm btn-ghost"
                  phx-click="close_bundle"
                  phx-value-bundle-id={bundle.id}
                  aria-label="Close bundle"
                >
                  Close
                </button>
                <button
                  type="button"
                  class="btn btn-sm btn-ghost"
                  phx-click="archive_bundle"
                  phx-value-bundle-id={bundle.id}
                  aria-label={"Archive bundle #{bundle.name}"}
                  data-confirm={"Archive #{bundle.name}?"}
                >
                  Archive
                </button>
                <button
                  type="button"
                  class="btn btn-sm btn-ghost text-error"
                  phx-click="soft_delete_bundle"
                  phx-value-bundle-id={bundle.id}
                  aria-label={"Delete bundle #{bundle.name}"}
                  data-confirm={"Delete #{bundle.name}?"}
                >
                  Delete
                </button>
              </div>

              <div
                :if={@open_bundle_id == bundle.id}
                id={"bundle-detail-#{bundle.id}"}
                class="mt-3 border-t border-base-300 pt-3 space-y-3"
              >
                <div :if={bundle.bundle_assets == []} class="text-sm text-base-content/60">
                  No assets in this bundle yet.
                </div>
                <ul :if={bundle.bundle_assets != []} class="space-y-1">
                  <li
                    :for={{ba, idx} <- Enum.with_index(bundle.bundle_assets)}
                    data-bundle-asset-row={ba.asset_id}
                    class="flex items-center gap-2 text-sm"
                  >
                    <span class="text-xs text-base-content/60 w-6">{idx + 1}.</span>
                    <span class="flex-1 truncate">{ba.asset.filename}</span>
                    <button
                      type="button"
                      class="btn btn-ghost btn-xs"
                      phx-click="reorder_bundle_asset"
                      phx-value-bundle-id={bundle.id}
                      phx-value-asset-id={ba.asset_id}
                      phx-value-direction="up"
                      disabled={idx == 0}
                      aria-label="Move up"
                    >
                      ↑
                    </button>
                    <button
                      type="button"
                      class="btn btn-ghost btn-xs"
                      phx-click="reorder_bundle_asset"
                      phx-value-bundle-id={bundle.id}
                      phx-value-asset-id={ba.asset_id}
                      phx-value-direction="down"
                      disabled={idx == length(bundle.bundle_assets) - 1}
                      aria-label="Move down"
                    >
                      ↓
                    </button>
                    <button
                      type="button"
                      class="btn btn-ghost btn-xs text-error"
                      phx-click="remove_bundle_asset"
                      phx-value-bundle-id={bundle.id}
                      phx-value-asset-id={ba.asset_id}
                      aria-label={"Remove #{ba.asset.filename} from bundle"}
                    >
                      ×
                    </button>
                  </li>
                </ul>

                <div class="border-t border-base-300 pt-3">
                  <p class="text-xs text-base-content/70 mb-1">Add from library</p>
                  <form phx-change="filter_picker_media" class="mb-2">
                    <input type="hidden" name="bundle-id" value={bundle.id} />
                    <select
                      name="media_type"
                      class="select select-bordered select-sm"
                      aria-label="Filter unattached assets by media type"
                    >
                      <option value="" selected={@picker_media_filter == ""}>All media</option>
                      <option value="image" selected={@picker_media_filter == "image"}>
                        Images
                      </option>
                      <option value="video" selected={@picker_media_filter == "video"}>
                        Videos
                      </option>
                    </select>
                  </form>
                  <div class="flex flex-wrap gap-1">
                    <button
                      :for={asset <- picker_candidates(@assets, bundle, @picker_media_filter)}
                      type="button"
                      data-picker-asset={asset.id}
                      class="btn btn-outline btn-xs"
                      phx-click="add_bundle_asset"
                      phx-value-bundle-id={bundle.id}
                      phx-value-asset-id={asset.id}
                    >
                      + {asset.filename}
                    </button>
                  </div>
                  <p
                    :if={picker_candidates(@assets, bundle, @picker_media_filter) == []}
                    class="text-xs text-base-content/60"
                  >
                    No more assets to add.
                  </p>
                </div>

                <div class="border-t border-base-300 pt-3">
                  <p class="text-sm font-semibold">Generate drafts</p>
                  <div
                    :if={MapSet.member?(@generating_bundle_ids, bundle.id)}
                    role="status"
                    aria-live="polite"
                    data-bundle-generating={bundle.id}
                    class="alert alert-info my-2"
                  >
                    <span>drafts generating...</span>
                  </div>

                  <p
                    :if={enabled_platforms(@product) == []}
                    class="text-xs text-base-content/60"
                  >
                    No publishing platforms are enabled for this product. Configure
                    publishing targets before generating drafts.
                  </p>

                  <form
                    :if={enabled_platforms(@product) != []}
                    phx-submit="generate_drafts"
                    class="space-y-2"
                  >
                    <input type="hidden" name="bundle-id" value={bundle.id} />
                    <fieldset class="flex flex-wrap gap-3">
                      <legend class="text-xs text-base-content/70 w-full">
                        Platforms
                      </legend>
                      <label
                        :for={platform <- enabled_platforms(@product)}
                        class="label cursor-pointer gap-2"
                      >
                        <input
                          type="checkbox"
                          name="platforms[]"
                          value={platform}
                          class="checkbox checkbox-sm"
                          checked
                        />
                        <span class="label-text capitalize">{platform}</span>
                      </label>
                    </fieldset>
                    <label class="form-control w-32">
                      <span class="label-text text-xs">Variants per platform</span>
                      <input
                        type="number"
                        name="variants_per_platform"
                        min="1"
                        max="10"
                        value="3"
                        class="input input-bordered input-sm"
                        aria-label="Variants per platform"
                      />
                    </label>
                    <p
                      :if={@bundle_generation_error}
                      class="text-xs text-error"
                    >
                      {@bundle_generation_error}
                    </p>
                    <div class="flex justify-end">
                      <button
                        type="submit"
                        class="btn btn-primary btn-sm"
                        disabled={MapSet.member?(@generating_bundle_ids, bundle.id)}
                      >
                        Generate drafts
                      </button>
                    </div>
                  </form>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </main>
    """
  end

  defp translate_bundle_error({msg, _opts}), do: msg
  defp translate_bundle_error(msg) when is_binary(msg), do: msg

  defp picker_candidates(assets, %AssetBundle{bundle_assets: members}, filter) do
    attached = MapSet.new(members, & &1.asset_id)

    assets
    |> Enum.reject(&MapSet.member?(attached, &1.id))
    |> filter_by_media(filter)
  end

  defp filter_by_media(list, nil), do: list
  defp filter_by_media(list, ""), do: list

  defp filter_by_media(list, media_type) when is_binary(media_type) do
    Enum.filter(list, &(&1.media_type == media_type))
  end

  defp error_to_string(:too_large), do: "File too large"
  defp error_to_string(:too_many_files), do: "Too many files selected"
  defp error_to_string(:not_accepted), do: "Unsupported file type"
  defp error_to_string(:external_client_failure), do: "Upload failed"
  defp error_to_string(other), do: to_string(other)

  defp format_bytes(nil), do: "-"

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1_024 -> "#{Float.round(bytes / 1_024, 1)} KB"
      true -> "#{bytes} B"
    end
  end
end
