defmodule ContentForgeWeb.Live.Dashboard.Drafts.ReviewLive do
  require Logger

  @moduledoc """
  LiveView for reviewing drafts: composite score, per-model scores, critiques, approve/reject.
  """
  use ContentForgeWeb, :live_view
  alias ContentForge.ContentGeneration
  alias ContentForge.Products
  alias ContentForgeWeb.Live.Dashboard.Components

  @impl true
  def mount(params, _session, socket) do
    drafts = fetch_drafts(params)
    products = Products.list_products()

    {:ok,
     assign(socket,
       drafts: drafts,
       products: products,
       selected_draft: nil,
       filter: Map.get(params, "filter", "all"),
       product_filter: Map.get(params, "product", "")
     )}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    drafts = fetch_drafts(%{"filter" => filter, "product" => socket.assigns.product_filter})
    {:noreply, assign(socket, drafts: drafts, filter: filter)}
  end

  @impl true
  def handle_event("filter_product", %{"product" => product_id}, socket) do
    drafts = fetch_drafts(%{"filter" => socket.assigns.filter, "product" => product_id})
    {:noreply, assign(socket, drafts: drafts, product_filter: product_id)}
  end

  @impl true
  def handle_event("select_draft", %{"id" => id}, socket) do
    draft = ContentGeneration.get_draft!(id)
    scores = ContentGeneration.get_scores_for_draft(id)
    composite = ContentGeneration.compute_composite_score(id)

    {:noreply,
     assign(socket,
       selected_draft: %{draft: draft, scores: scores, composite: composite}
     )}
  end

  @impl true
  def handle_event("approve_draft", %{"id" => id}, socket) do
    draft = ContentGeneration.get_draft!(id)

    case ContentGeneration.mark_draft_approved(draft) do
      {:ok, _} ->
        Logger.info("Approved draft: #{id}")

        drafts =
          fetch_drafts(%{
            "filter" => socket.assigns.filter,
            "product" => socket.assigns.product_filter
          })

        {:noreply, assign(socket, drafts: drafts, selected_draft: nil)}

      {:error, changeset} ->
        Logger.error("Failed to approve draft: #{inspect(changeset.errors)}")
        {:noreply, put_flash(socket, :error, "Failed to approve draft")}
    end
  end

  @impl true
  def handle_event("reject_draft", %{"id" => id}, socket) do
    draft = ContentGeneration.get_draft!(id)

    case ContentGeneration.mark_draft_rejected(draft) do
      {:ok, _} ->
        Logger.info("Rejected draft: #{id}")

        drafts =
          fetch_drafts(%{
            "filter" => socket.assigns.filter,
            "product" => socket.assigns.product_filter
          })

        {:noreply, assign(socket, drafts: drafts, selected_draft: nil)}

      {:error, changeset} ->
        Logger.error("Failed to reject draft: #{inspect(changeset.errors)}")
        {:noreply, put_flash(socket, :error, "Failed to reject draft")}
    end
  end

  @impl true
  def handle_event("close_detail", _params, socket) do
    {:noreply, assign(socket, selected_draft: nil)}
  end

  defp fetch_drafts(params) do
    filter = Map.get(params, "filter", "all")
    product_id = Map.get(params, "product", "")

    drafts =
      case {filter, product_id} do
        {"ranked", ""} ->
          ContentGeneration.list_drafts_by_status(nil, "ranked")

        {"approved", ""} ->
          ContentGeneration.list_drafts_by_status(nil, "approved")

        {"rejected", ""} ->
          ContentGeneration.list_drafts_by_status(nil, "rejected")

        {"all", ""} ->
          ContentGeneration.list_drafts()

        {_, ""} ->
          ContentGeneration.list_drafts_by_status(nil, filter)

        {_, product_id} when product_id != "" ->
          drafts = ContentGeneration.list_drafts_for_product(product_id)

          case filter do
            "all" -> drafts
            f -> Enum.filter(drafts, &(&1.status == f))
          end
      end

    Enum.map(drafts, fn draft ->
      scores = ContentGeneration.get_scores_for_draft(draft.id)
      composite = ContentGeneration.compute_composite_score(draft.id)
      %{draft: draft, scores: scores, composite: composite}
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h1 class="text-2xl font-bold">Draft Review Queue</h1>
        <p class="text-base-content/70">Review and approve generated drafts</p>
      </div>
      
    <!-- Filters -->
      <div class="flex flex-col sm:flex-row gap-4">
        <div class="tabs tabs-boxed">
          <button
            class={["tab", @filter == "all" && "tab-active"]}
            phx-click="filter"
            phx-value-filter="all"
          >
            All
          </button>
          <button
            class={["tab", @filter == "draft" && "tab-active"]}
            phx-click="filter"
            phx-value-filter="draft"
          >
            Draft
          </button>
          <button
            class={["tab", @filter == "ranked" && "tab-active"]}
            phx-click="filter"
            phx-value-filter="ranked"
          >
            Ranked
          </button>
          <button
            class={["tab", @filter == "approved" && "tab-active"]}
            phx-click="filter"
            phx-value-filter="approved"
          >
            Approved
          </button>
          <button
            class={["tab", @filter == "rejected" && "tab-active"]}
            phx-click="filter"
            phx-value-filter="rejected"
          >
            Rejected
          </button>
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
      
    <!-- Stats -->
      <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
        <div class="stat bg-base-200">
          <div class="stat-title">Total</div>
          <div class="stat-value">{length(@drafts)}</div>
        </div>
        <div class="stat bg-base-200">
          <div class="stat-title">Ranked (Ready)</div>
          <div class="stat-value text-warning">
            {Enum.filter(@drafts, &(&1.draft.status == "ranked")) |> length}
          </div>
        </div>
        <div class="stat bg-base-200">
          <div class="stat-title">Approved</div>
          <div class="stat-value text-success">
            {Enum.filter(@drafts, &(&1.draft.status == "approved")) |> length}
          </div>
        </div>
        <div class="stat bg-base-200">
          <div class="stat-title">Avg Score</div>
          <div class="stat-value text-lg">
            {avg_score(@drafts)}
          </div>
        </div>
      </div>
      
    <!-- Drafts List -->
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <div class="space-y-2">
          <h2 class="font-semibold">Drafts ({length(@drafts)})</h2>
          <div class="overflow-y-auto max-h-[600px] space-y-2">
            <div
              :for={item <- @drafts}
              class={"card bg-base-200 hover:bg-base-300 cursor-pointer transition-colors #{if @selected_draft && @selected_draft.draft.id == item.draft.id, do: "border-2 border-primary"}"}
              phx-click="select_draft"
              phx-value-id={item.draft.id}
            >
              <div class="card-body p-4">
                <div class="flex justify-between items-start">
                  <div>
                    <div class="flex items-center gap-2">
                      <span class="font-semibold">{item.draft.platform}</span>
                      <span class="badge badge-sm">{item.draft.content_type}</span>
                    </div>
                    <p class="text-xs text-base-content/70 mt-1">
                      {item.draft.generating_model} | {Components.format_datetime(
                        item.draft.inserted_at
                      )}
                    </p>
                  </div>
                  <div class="text-right">
                    <Components.status_badge status={item.draft.status} />
                    <div :if={item.composite} class="mt-2">
                      <Components.score_display score={item.composite} />
                    </div>
                  </div>
                </div>
                <p class="text-sm mt-2 line-clamp-2">
                  {String.slice(item.draft.content || "", 0, 150)}...
                </p>
              </div>
            </div>

            <div :if={length(@drafts) == 0} class="text-center py-8 text-base-content/70">
              No drafts found
            </div>
          </div>
        </div>
        
    <!-- Detail Panel -->
        <div :if={@selected_draft} class="card bg-base-200 sticky top-4">
          <div class="card-body">
            <div class="flex justify-between items-start">
              <h2 class="card-title">Draft Details</h2>
              <button phx-click="close_detail" class="btn btn-ghost btn-sm btn-circle">
                <.icon name="hero-x" class="size-4" />
              </button>
            </div>
            
    <!-- Scores -->
            <div class="bg-base-300 rounded-lg p-4 mb-4">
              <h3 class="font-semibold mb-3">Model Scores</h3>
              <div class="grid grid-cols-2 gap-2">
                <div :for={score <- @selected_draft.scores} class="flex justify-between">
                  <span class="text-sm">{score.model_name}</span>
                  <Components.score_display score={score.composite_score} />
                </div>
              </div>
              <div class="divider">Composite</div>
              <div class="flex justify-between items-center">
                <span class="font-semibold">Overall Score</span>
                <Components.score_display score={@selected_draft.composite || 0} />
              </div>
            </div>
            
    <!-- Critiques -->
            <div :if={length(@selected_draft.scores) > 0} class="mb-4">
              <h3 class="font-semibold mb-2">Critiques</h3>
              <div class="space-y-2">
                <div :for={score <- @selected_draft.scores} class="bg-base-300 rounded p-3">
                  <p class="text-sm font-medium">{score.model_name}</p>
                  <p class="text-xs text-base-content/70">{score.critique || "No critique"}</p>
                  <div class="flex gap-4 mt-2 text-xs">
                    <span>Accuracy: {Float.round(score.accuracy_score, 1)}</span>
                    <span>SEO: {Float.round(score.seo_score, 1)}</span>
                    <span>EEV: {Float.round(score.eev_score, 1)}</span>
                  </div>
                </div>
              </div>
            </div>
            
    <!-- Content -->
            <div class="mb-4">
              <h3 class="font-semibold mb-2">Content</h3>
              <div class="bg-base-300 rounded p-3 text-sm whitespace-pre-wrap max-h-48 overflow-y-auto">
                {@selected_draft.draft.content}
              </div>
            </div>
            
    <!-- Actions -->
            <div class="flex gap-2 justify-end">
              <button
                :if={@selected_draft.draft.status in ["draft", "ranked"]}
                class="btn btn-error"
                phx-click="reject_draft"
                phx-value-id={@selected_draft.draft.id}
              >
                Reject
              </button>
              <button
                :if={@selected_draft.draft.status in ["draft", "ranked"]}
                class="btn btn-success"
                phx-click="approve_draft"
                phx-value-id={@selected_draft.draft.id}
              >
                Approve
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp avg_score([]), do: "—"

  defp avg_score(drafts) do
    scores = drafts |> Enum.filter(& &1.composite) |> Enum.map(& &1.composite)

    if scores == [] do
      "—"
    else
      Float.round(Enum.sum(scores) / length(scores), 1)
    end
  end
end
