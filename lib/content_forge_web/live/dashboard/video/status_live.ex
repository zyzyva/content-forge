defmodule ContentForgeWeb.Live.Dashboard.Video.StatusLive do
  require Logger

  @moduledoc """
  LiveView for video production status board showing all video jobs and their progress.
  """
  use ContentForgeWeb, :live_view
  alias ContentForge.ContentGeneration
  alias ContentForge.Products
  alias ContentForge.Publishing
  alias ContentForgeWeb.Live.Dashboard.Components

  @status_order ~w(script_approved voiceover_done recording_done avatar_done assembled encoded uploaded)

  @impl true
  def mount(params, _session, socket) do
    products = Products.list_products()
    product_id = Map.get(params, "product", "")

    {:ok,
     assign(socket,
       products: products,
       product_filter: product_id,
       video_jobs: fetch_jobs(product_id),
       selected_job: nil,
       candidate_scripts: fetch_candidates(product_id),
       script_gate_threshold: Publishing.script_gate_threshold(),
       status_order: @status_order
     )}
  end

  @impl true
  def handle_event("filter_product", %{"product" => product_id}, socket) do
    {:noreply,
     assign(socket,
       product_filter: product_id,
       video_jobs: fetch_jobs(product_id),
       candidate_scripts: fetch_candidates(product_id)
     )}
  end

  @impl true
  def handle_event("promote_script", %{"draft-id" => draft_id}, socket) do
    case Publishing.promote_script(draft_id) do
      {:ok, job} ->
        Logger.info(
          "Promoted script #{draft_id} via #{override_label(job.promoted_via_override)}"
        )

        {:noreply,
         socket
         |> put_flash(:info, flash_for_promotion(job))
         |> assign(
           video_jobs: fetch_jobs(socket.assigns.product_filter),
           candidate_scripts: fetch_candidates(socket.assigns.product_filter)
         )}

      {:error, reason} ->
        Logger.error("Failed to promote script #{draft_id}: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Failed to promote script")}
    end
  end

  @impl true
  def handle_event("select_job", %{"id" => id}, socket) do
    job = Publishing.get_video_job(id)
    {:noreply, assign(socket, selected_job: job)}
  end

  @impl true
  def handle_event("pause_job", %{"id" => id}, socket) do
    job = Publishing.get_video_job(id)

    case Publishing.pause_video_job(job, "Paused by user") do
      {:ok, _} ->
        Logger.info("Paused video job: #{id}")
        video_jobs = fetch_jobs(socket.assigns.product_filter)
        {:noreply, assign(socket, video_jobs: video_jobs, selected_job: nil)}

      {:error, changeset} ->
        Logger.error("Failed to pause video job: #{inspect(changeset.errors)}")
        {:noreply, put_flash(socket, :error, "Failed to pause job")}
    end
  end

  @impl true
  def handle_event("resume_job", %{"id" => id}, socket) do
    job = Publishing.get_video_job(id)

    case Publishing.resume_video_job(job) do
      {:ok, _} ->
        Logger.info("Resumed video job: #{id}")
        video_jobs = fetch_jobs(socket.assigns.product_filter)
        {:noreply, assign(socket, video_jobs: video_jobs, selected_job: nil)}

      {:error, changeset} ->
        Logger.error("Failed to resume video job: #{inspect(changeset.errors)}")
        {:noreply, put_flash(socket, :error, "Failed to resume job")}
    end
  end

  @impl true
  def handle_event("close_detail", _params, socket) do
    {:noreply, assign(socket, selected_job: nil)}
  end

  defp override_label(true), do: "override"
  defp override_label(false), do: "standard promote"

  defp flash_for_promotion(%Publishing.VideoJob{promoted_via_override: true}),
    do: "Promoted script via manual override"

  defp flash_for_promotion(%Publishing.VideoJob{}), do: "Promoted script to video production"

  defp fetch_jobs(""), do: Publishing.list_video_jobs(limit: 100)
  defp fetch_jobs(product_id), do: Publishing.list_video_jobs(product_id: product_id, limit: 100)

  # Candidate scripts = ranked or archived video_script Drafts that have
  # no VideoJob yet. `composite_score` is hydrated per row so the
  # template can render it alongside the threshold.
  defp fetch_candidates(""), do: candidate_scripts_for_products(Products.list_products())

  defp fetch_candidates(product_id) do
    case Products.get_product(product_id) do
      nil -> []
      product -> candidate_scripts_for_products([product])
    end
  end

  defp candidate_scripts_for_products(products) do
    products
    |> Enum.flat_map(fn product ->
      ContentGeneration.list_drafts_by_type(product.id, "video_script")
      |> Enum.filter(&(&1.status in ["ranked", "archived"]))
      |> Enum.reject(&existing_video_job?/1)
      |> Enum.map(fn draft ->
        %{
          draft: draft,
          product: product,
          composite_score: ContentGeneration.compute_composite_score(draft.id)
        }
      end)
    end)
    |> Enum.sort_by(&candidate_sort_key/1)
  end

  defp existing_video_job?(draft) do
    Publishing.get_video_job_by_draft(draft.id) != nil
  end

  # Highest score first (nil goes last).
  defp candidate_sort_key(%{composite_score: nil}), do: {1, 0.0}
  defp candidate_sort_key(%{composite_score: s}), do: {0, -s}

  # Helper functions

  defp in_progress_count(jobs) do
    Enum.filter(jobs, fn job ->
      job.status not in ["uploaded", "failed", "paused"]
    end)
    |> length
  end

  defp count_at_step(jobs, step) do
    step_index = Enum.find_index(@status_order, &(&1 == step))

    Enum.filter(jobs, fn job ->
      job_index = Enum.find_index(@status_order, &(&1 == job.status))
      job_index && job_index >= step_index
    end)
    |> length
  end

  defp step_status_class(step, jobs) do
    count = count_at_step(jobs, step)

    if count == 0 do
      "bg-base-300 opacity-50"
    else
      if step == "uploaded" do
        "bg-success/20"
      else
        "bg-warning/20"
      end
    end
  end

  defp format_step_name("script_approved"), do: "Script"
  defp format_step_name("voiceover_done"), do: "Voiceover"
  defp format_step_name("recording_done"), do: "Recording"
  defp format_step_name("avatar_done"), do: "Avatar"
  defp format_step_name("assembled"), do: "Assemble"
  defp format_step_name("encoded"), do: "Encode"
  defp format_step_name("uploaded"), do: "Uploaded"
  defp format_step_name(step), do: step

  defp job_progress(job) do
    step_index = Enum.find_index(@status_order, &(&1 == job.status))
    total = length(@status_order)

    if step_index do
      "#{step_index + 1}/#{total}"
    else
      "—"
    end
  end

  defp job_progress_percent(job) do
    step_index = Enum.find_index(@status_order, &(&1 == job.status))
    total = length(@status_order)

    if step_index do
      (step_index + 1) * 100 / total
    else
      0
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main-content" aria-labelledby="page-title" class="space-y-6">
      <header class="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
        <div>
          <h1 id="page-title" class="text-2xl font-bold">Video Production</h1>
          <p class="text-base-content/70">Track video creation pipeline</p>
        </div>
        <label class="form-control">
          <span class="label-text sr-only">Filter by product</span>
          <select
            class="select select-bordered"
            name="product"
            aria-label="Filter by product"
            phx-change="filter_product"
          >
            <option value="">All Products</option>
            <option :for={product <- @products} value={product.id}>
              {product.name}
            </option>
          </select>
        </label>
      </header>
      
    <!-- Stats -->
      <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
        <div class="stat bg-base-200">
          <div class="stat-title">Total</div>
          <div class="stat-value">{length(@video_jobs)}</div>
        </div>
        <div class="stat bg-base-200">
          <div class="stat-title">In Progress</div>
          <div class="stat-value text-warning">
            {in_progress_count(@video_jobs)}
          </div>
        </div>
        <div class="stat bg-base-200">
          <div class="stat-title">Completed</div>
          <div class="stat-value text-success">
            {Enum.filter(@video_jobs, &(&1.status == "uploaded")) |> length}
          </div>
        </div>
        <div class="stat bg-base-200">
          <div class="stat-title">Failed/Paused</div>
          <div class="stat-value text-error">
            {Enum.filter(@video_jobs, &(&1.status in ["failed", "paused"])) |> length}
          </div>
        </div>
      </div>
      
    <!-- Pipeline Visualization -->
      <div class="card bg-base-200">
        <div class="card-body">
          <h2 class="card-title">Pipeline</h2>
          <div class="flex flex-wrap gap-2 justify-center md:justify-start">
            <%= for step <- @status_order do %>
              <div class={"px-4 py-2 rounded-lg text-center min-w-24 #{step_status_class(step, @video_jobs)}"}>
                <div class="text-xs font-semibold">{format_step_name(step)}</div>
                <div class="text-lg font-bold">
                  {count_at_step(@video_jobs, step)}
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>
      
    <!-- Script Gate (candidates awaiting promotion) -->
      <div class="card bg-base-200">
        <div class="card-body">
          <div class="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-2">
            <h2 class="card-title">Script Gate</h2>
            <div class="text-xs text-base-content/70">
              Threshold:
              <span class="font-mono" data-script-gate-threshold>{@script_gate_threshold}</span>
            </div>
          </div>

          <div
            :if={@candidate_scripts == []}
            class="text-center py-6 text-base-content/70"
          >
            No ranked scripts awaiting the gate
          </div>

          <div :if={@candidate_scripts != []} class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Product</th>
                  <th>Script</th>
                  <th>Composite</th>
                  <th>Status vs threshold</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={candidate <- @candidate_scripts}
                  id={"script-candidate-#{candidate.draft.id}"}
                  data-script-candidate={candidate.draft.id}
                  data-below-threshold={below?(candidate, @script_gate_threshold)}
                >
                  <td>{candidate.product.name}</td>
                  <td class="max-w-xs truncate">
                    {String.slice(candidate.draft.content || "", 0, 80)}
                  </td>
                  <td class="font-mono">{format_score(candidate.composite_score)}</td>
                  <td>
                    <span class={score_badge_class(candidate, @script_gate_threshold)}>
                      {score_label(candidate, @script_gate_threshold)}
                    </span>
                  </td>
                  <td>
                    <button
                      type="button"
                      class={promote_button_class(candidate, @script_gate_threshold)}
                      phx-click="promote_script"
                      phx-value-draft-id={candidate.draft.id}
                      data-confirm={promote_confirm(candidate, @script_gate_threshold)}
                      aria-label={promote_label(candidate, @script_gate_threshold)}
                    >
                      {promote_label(candidate, @script_gate_threshold)}
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
      
    <!-- Video Jobs List -->
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <section aria-labelledby="video-jobs-heading" class="space-y-2">
          <h2 id="video-jobs-heading" class="font-semibold">
            Video Jobs ({length(@video_jobs)})
          </h2>
          <ul class="overflow-y-auto max-h-[600px] space-y-2">
            <li :for={job <- @video_jobs} class="list-none">
              <button
                type="button"
                class={[
                  "w-full text-left card bg-base-200 hover:bg-base-300 transition-colors focus:outline-none focus:ring focus:ring-primary",
                  @selected_job && @selected_job.id == job.id && "border-2 border-primary"
                ]}
                phx-click="select_job"
                phx-value-id={job.id}
                aria-label={"Select video job, status #{job.status}, progress #{job_progress(job)}"}
                aria-pressed={
                  if @selected_job && @selected_job.id == job.id, do: "true", else: "false"
                }
              >
                <div class="card-body p-4" data-video-job-id={job.id}>
                  <div class="flex justify-between items-start">
                    <div>
                      <div class="flex items-center gap-2">
                        <Components.status_badge status={job.status} />
                        <span
                          :if={job.promoted_via_override}
                          class="badge badge-warning badge-sm"
                          data-promoted-override={job.id}
                          aria-label="Promoted via manual override"
                        >
                          OVERRIDE
                        </span>
                      </div>
                      <p class="text-xs text-base-content/70 mt-1">
                        Created: {Components.format_datetime(job.inserted_at)}
                      </p>
                    </div>
                    <div class="text-right">
                      <div class="text-xs text-base-content/70">Progress</div>
                      <div class="text-sm font-semibold">
                        {job_progress(job)}
                      </div>
                    </div>
                  </div>
                  <div class="mt-2">
                    <div
                      class="progress progress-primary w-full h-2"
                      role="progressbar"
                      aria-label={"Pipeline progress #{job_progress(job)}"}
                      aria-valuenow={round(job_progress_percent(job))}
                      aria-valuemin="0"
                      aria-valuemax="100"
                    >
                      <div style={"width: #{job_progress_percent(job)}%"}></div>
                    </div>
                  </div>
                </div>
              </button>
            </li>
          </ul>

          <p
            :if={length(@video_jobs) == 0}
            class="text-center py-8 text-base-content/70"
            role="status"
          >
            No video jobs found
          </p>
        </section>
        
    <!-- Detail Panel -->
        <aside
          :if={@selected_job}
          role="region"
          aria-labelledby="video-job-details-heading"
          class="card bg-base-200 sticky top-4"
        >
          <div class="card-body">
            <div class="flex justify-between items-start">
              <h2 id="video-job-details-heading" class="card-title">Job Details</h2>
              <button
                phx-click="close_detail"
                class="btn btn-ghost btn-sm btn-circle"
                aria-label="Close job details"
              >
                <span aria-hidden="true">
                  <.icon name="hero-x" class="size-4" />
                </span>
              </button>
            </div>
            
    <!-- Status Steps -->
            <div class="steps steps-vertical w-full mt-4">
              <%= for step <- @status_order do %>
                <div class={
                  if step_index(@selected_job.status) >= step_index(step),
                    do: "step step-primary",
                    else: "step"
                }>
                  <div class="text-xs">{format_step_name(step)}</div>
                </div>
              <% end %>
            </div>
            
    <!-- R2 Keys -->
            <div
              :if={@selected_job.per_step_r2_keys && @selected_job.per_step_r2_keys != %{}}
              class="mt-4"
            >
              <h3 class="font-semibold mb-2">Assets</h3>
              <div class="space-y-1 text-xs">
                <div :for={{key, value} <- @selected_job.per_step_r2_keys}>
                  <span class="text-base-content/70">{key}:</span>
                  <span class="font-mono">{String.slice(value || "", 0, 30)}...</span>
                </div>
              </div>
            </div>
            
    <!-- Error -->
            <div :if={@selected_job.error} class="mt-4 bg-error/20 rounded p-3">
              <p class="text-sm text-error">Error: {@selected_job.error}</p>
            </div>
            
    <!-- Actions -->
            <div class="flex gap-2 justify-end mt-4">
              <button
                :if={@selected_job.status not in ["uploaded", "paused", "failed"]}
                class="btn btn-warning"
                phx-click="pause_job"
                phx-value-id={@selected_job.id}
              >
                Pause
              </button>
              <button
                :if={@selected_job.status == "paused"}
                class="btn btn-success"
                phx-click="resume_job"
                phx-value-id={@selected_job.id}
              >
                Resume
              </button>
            </div>
          </div>
        </aside>
      </div>
    </main>
    """
  end

  defp step_index(status) do
    Enum.find_index(@status_order, &(&1 == status)) || 0
  end

  # --- script-gate helpers -------------------------------------------------

  defp format_score(nil), do: "—"
  defp format_score(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)

  defp below?(%{composite_score: nil}, _), do: "true"
  defp below?(%{composite_score: s}, threshold) when s < threshold, do: "true"
  defp below?(_, _), do: "false"

  defp score_badge_class(candidate, threshold) do
    case below?(candidate, threshold) do
      "true" -> "badge badge-warning"
      "false" -> "badge badge-success"
    end
  end

  defp score_label(%{composite_score: nil}, _), do: "UNSCORED"
  defp score_label(%{composite_score: s}, t) when s >= t, do: "ABOVE"
  defp score_label(_, _), do: "BELOW"

  defp promote_button_class(candidate, threshold) do
    case below?(candidate, threshold) do
      "true" -> "btn btn-warning btn-sm"
      "false" -> "btn btn-primary btn-sm"
    end
  end

  defp promote_label(%{composite_score: nil}, _), do: "Override promote"
  defp promote_label(%{composite_score: s}, t) when s < t, do: "Override promote"
  defp promote_label(_, _), do: "Promote"

  defp promote_confirm(%{composite_score: nil}, _),
    do: "Promote with no ranking scores on file?"

  defp promote_confirm(%{composite_score: s}, t) when s < t do
    "Composite #{format_score(s)} is below threshold #{format_score(t)}. Override?"
  end

  defp promote_confirm(_, _), do: nil
end
