defmodule ContentForge.Jobs.ScriptGate do
  use Oban.Worker, queue: :content_generation, max_attempts: 3
  require Logger

  alias ContentForge.ContentGeneration
  alias ContentForge.ContentGeneration.Draft
  alias ContentForge.Publishing

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

    Logger.info(
      "Script gate: evaluating #{length(scripts)} video scripts with threshold #{threshold}"
    )

    results =
      Enum.map(scripts, fn script ->
        # Get composite score
        composite = ContentGeneration.compute_composite_score(script.id) || 0

        if composite >= threshold do
          promote_to_video(script, composite, threshold)
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

  defp promote_to_video(%Draft{} = script, composite, threshold) do
    # Promote via the blessed path: creates a VideoJob row and
    # enqueues VideoProducer with the matching video_job_id inside
    # a single transaction. Replaces a historical hand-rolled
    # Oban.insert(%Oban.Job{...}) call that referenced a
    # non-existent worker module and the wrong args.
    {:ok, _video_job} =
      Publishing.promote_script(script.id,
        score: composite,
        threshold: threshold
      )

    :ok
  end
end
