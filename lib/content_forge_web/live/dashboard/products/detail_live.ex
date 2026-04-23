defmodule ContentForgeWeb.Live.Dashboard.Products.DetailLive do
  require Logger

  @moduledoc """
  LiveView for per-product details: snapshot status, brief, draft queue, publishing history.
  """
  use ContentForgeWeb, :live_view
  alias ContentForge.ContentGeneration
  alias ContentForge.Jobs.AssetImageProcessor
  alias ContentForge.Jobs.AssetVideoProcessor
  alias ContentForge.ProductAssets
  alias ContentForge.ProductAssets.ProductAsset
  alias ContentForge.Products
  alias ContentForge.Publishing
  alias ContentForgeWeb.Live.Dashboard.Components

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

    if connected?(socket), do: ProductAssets.subscribe(product_id)

    {:ok,
     socket
     |> assign(
       product: product,
       snapshots: snapshots,
       brief: brief,
       drafts: drafts,
       published_posts: published_posts,
       assets: assets,
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

    assets = ProductAssets.list_assets(socket.assigns.product.id)

    socket =
      socket
      |> assign(assets: assets)
      |> put_flash(:info, "#{length(created)} asset(s) registered")

    {:noreply, socket}
  end

  @impl true
  def handle_info({event, asset}, socket)
      when event in [:asset_created, :asset_updated, :asset_deleted] do
    assets = ProductAssets.list_assets(socket.assigns.product.id)
    {:noreply, assign(socket, assets: assets, last_asset_event: {event, asset.id})}
  end

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
        <button
          role="tab"
          class={["tab", @active_tab == "assets" && "tab-active"]}
          phx-click="switch_tab"
          phx-value-tab="assets"
        >
          Assets
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
            <div :if={@assets == []} class="text-center py-8 text-base-content/70">
              No assets yet
            </div>
            <div :if={@assets != []} class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Filename</th>
                    <th>Type</th>
                    <th>Size</th>
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
    </div>
    """
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
