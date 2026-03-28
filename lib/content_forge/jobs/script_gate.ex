defmodule ContentForge.Jobs.ScriptGate do
  use Oban.Worker, queue: :content_generation, max_attempts: 3
  require Logger

  alias ContentForge.ContentGeneration
  alias ContentForge.ContentGeneration.Draft

  @default_threshold 6.0

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"product_id" => product_id, "threshold" => threshold}}) do
    evaluate_scripts(product_id, threshold || @default_threshold)
  end

  def perform(%Oban.Job{args: %{"product_id" => product_id}}) do
    evaluate_scripts(product_id, @default_threshold)
  end

  defp evaluate_scripts(product_id, threshold) do
    # Get all ranked video scripts
    scripts =
      ContentGeneration.list_drafts_by_type(product_id, "video_script")
      |> Enum.filter(fn d -> d.status == "ranked" end)

    Logger.info("Script gate: evaluating #{length(scripts)} video scripts with threshold #{threshold}")

    results =
      Enum.map(scripts, fn script ->
        # Get composite score
        composite = ContentGeneration.compute_composite_score(script.id) || 0

        if composite >= threshold do
          # Approve script and enqueue video production
          ContentGeneration.update_draft_status(script, "approved")
          enqueue_video_production(script)
          Logger.info("Script #{script.id} approved for production (score: #{composite})")
          {:approved, script.id, composite}
        else
          # Archive script
          ContentGeneration.update_draft_status(script, "archived")
          Logger.info("Script #{script.id} archived (score: #{composite} < #{threshold})")
          {:archived, script.id, composite}
        end
      end)

    approved_count =
      Enum.count(results, fn
        {:approved, _, _} -> true
        _ -> false
      end)

    archived_count =
      Enum.count(results, fn
        {:archived, _, _} -> true
        _ -> false
      end)

    Logger.info("Script gate complete: #{approved_count} approved, #{archived_count} archived")

    %{approved: approved_count, archived: archived_count}
  end

  defp enqueue_video_production(%Draft{} = script) do
    # Enqueue the video production job
    # This will be implemented in Phase 6
    Oban.insert(%Oban.Job{
      queue: :video_production,
      worker: "ContentForge.Jobs.VideoProduction",
      args: %{
        "script_id" => script.id,
        "product_id" => script.product_id
      },
      max_attempts: 3
    })

    Logger.info("Enqueued video production job for script #{script.id}")
  end
end