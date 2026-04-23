defmodule ContentForgeWeb.Live.Dashboard.Video.StatusLive do
  require Logger

  @moduledoc """
  LiveView for video production status board showing all video jobs and their progress.
  """
  use ContentForgeWeb, :live_view
  alias ContentForge.Publishing
  alias ContentForge.Products
  alias ContentForgeWeb.Live.Dashboard.Components

  @status_order ~w(script_approved voiceover_done recording_done avatar_done assembled encoded uploaded)

  @impl true
  def mount(params, _session, socket) do
    products = Products.list_products()
    product_id = Map.get(params, "product", "")

    video_jobs =
      if product_id == "" do
        Publishing.list_video_jobs(limit: 100)
      else
        Publishing.list_video_jobs(product_id: product_id, limit: 100)
      end

    {:ok,
     assign(socket,
       products: products,
       product_filter: product_id,
       video_jobs: video_jobs,
       selected_job: nil
     )}
  end

  @impl true
  def handle_event("filter_product", %{"product" => product_id}, socket) do
    video_jobs =
      if product_id == "" do
        Publishing.list_video_jobs(limit: 100)
      else
        Publishing.list_video_jobs(product_id: product_id, limit: 100)
      end

    {:noreply,
     assign(socket,
       product_filter: product_id,
       video_jobs: video_jobs
     )}
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

  defp fetch_jobs(""), do: Publishing.list_video_jobs(limit: 100)
  defp fetch_jobs(product_id), do: Publishing.list_video_jobs(product_id: product_id, limit: 100)

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
    <div class="space-y-6">
      <div class="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
        <div>
          <h1 class="text-2xl font-bold">Video Production</h1>
          <p class="text-base-content/70">Track video creation pipeline</p>
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
      
    <!-- Video Jobs List -->
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <div class="space-y-2">
          <h2 class="font-semibold">Video Jobs ({length(@video_jobs)})</h2>
          <div class="overflow-y-auto max-h-[600px] space-y-2">
            <div
              :for={job <- @video_jobs}
              class={"card bg-base-200 hover:bg-base-300 cursor-pointer transition-colors #{if @selected_job && @selected_job.id == job.id, do: "border-2 border-primary"}"}
              phx-click="select_job"
              phx-value-id={job.id}
            >
              <div class="card-body p-4">
                <div class="flex justify-between items-start">
                  <div>
                    <div class="flex items-center gap-2">
                      <Components.status_badge status={job.status} />
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
                  <div class="progress progress-primary w-full h-2">
                    <div
                      style={"width: #{job_progress_percent(job)}%"}
                      role="progressbar"
                    >
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <div :if={length(@video_jobs) == 0} class="text-center py-8 text-base-content/70">
              No video jobs found
            </div>
          </div>
        </div>
        
    <!-- Detail Panel -->
        <div :if={@selected_job} class="card bg-base-200 sticky top-4">
          <div class="card-body">
            <div class="flex justify-between items-start">
              <h2 class="card-title">Job Details</h2>
              <button phx-click="close_detail" class="btn btn-ghost btn-sm btn-circle">
                <.icon name="hero-x" class="size-4" />
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
        </div>
      </div>
    </div>
    """
  end

  defp step_index(status) do
    Enum.find_index(@status_order, &(&1 == status)) || 0
  end
end
