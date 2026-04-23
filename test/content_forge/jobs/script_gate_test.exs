defmodule ContentForge.Jobs.ScriptGateTest do
  @moduledoc """
  Behavioral coverage for `ContentForge.Jobs.ScriptGate`, added as
  part of the 15.4.2 Oban.insert audit sweep.

  Pre-fix the worker called `Oban.insert(%Oban.Job{...})` with a
  raw struct that referenced a non-existent worker module
  (`"ContentForge.Jobs.VideoProduction"`) and args that wouldn't
  have matched `VideoProducer.perform/1` even if it did exist.
  The fix routes the enqueue through `Publishing.promote_script/2`
  which creates a `VideoJob` and enqueues `VideoProducer` with the
  matching `video_job_id`, transactionally.
  """
  use ContentForge.DataCase, async: true
  use Oban.Testing, repo: ContentForge.Repo

  alias ContentForge.ContentGeneration
  alias ContentForge.Jobs.ScriptGate
  alias ContentForge.Jobs.VideoProducer
  alias ContentForge.Products
  alias ContentForge.Publishing

  setup do
    {:ok, product} =
      Products.create_product(%{
        name: "Script Gate Product",
        voice_profile: "professional"
      })

    %{product: product}
  end

  describe "perform/1" do
    test "approves scripts scoring at or above threshold and enqueues VideoProducer",
         %{product: product} do
      {:ok, script} = insert_ranked_script(product)
      :ok = insert_composite_score(script, 7.5)

      # perform/1 is called directly rather than via perform_job/2
      # because the worker returns a bare summary map; Oban's
      # testing helper rejects that shape as invalid. The return
      # shape is an existing issue, out of scope for the
      # enqueue-audit slice.
      assert %{approved: 1, archived: 0} =
               ScriptGate.perform(%Oban.Job{
                 args: %{"product_id" => product.id, "threshold" => 6.0}
               })

      # Script was promoted + a VideoJob exists.
      script_id = script.id
      assert %{status: "approved"} = ContentGeneration.get_draft(script_id)
      assert [%{draft_id: ^script_id} = video_job] = list_video_jobs_for_draft(script_id)

      # VideoProducer job was enqueued for the new VideoJob, not
      # for the script directly. This is the contract that the
      # pre-fix bare-struct enqueue violated.
      assert_enqueued(worker: VideoProducer, args: %{"video_job_id" => video_job.id})
    end

    test "does not promote or enqueue scripts scoring below threshold",
         %{product: product} do
      {:ok, script} = insert_ranked_script(product)
      :ok = insert_composite_score(script, 3.0)

      assert %{approved: 0, archived: 1} =
               ScriptGate.perform(%Oban.Job{
                 args: %{"product_id" => product.id, "threshold" => 6.0}
               })

      # Sub-threshold scripts do NOT get promoted to "approved"
      # and do NOT trigger a VideoProducer job. The worker also
      # attempts to mark them "archived", but that's a separate
      # schema issue (archived is not in the draft-status
      # inclusion list) and is out of scope here - we only assert
      # the enqueue-shape contract: no video production job fires.
      refute_enqueued(worker: VideoProducer)
      refute ContentGeneration.get_draft(script.id).status == "approved"
      assert Publishing.get_video_job_by_draft(script.id) == nil
    end
  end

  defp insert_ranked_script(product) do
    ContentGeneration.create_draft(%{
      "product_id" => product.id,
      "content" => "video script text",
      "platform" => "youtube",
      "content_type" => "video_script",
      "generating_model" => "test",
      "status" => "ranked"
    })
  end

  defp insert_composite_score(script, value) do
    {:ok, _} =
      ContentGeneration.create_draft_score(%{
        draft_id: script.id,
        model_name: "claude",
        composite_score: value,
        accuracy_score: value,
        seo_score: value,
        eev_score: value,
        critique: "test"
      })

    :ok
  end

  defp list_video_jobs_for_draft(draft_id) do
    case Publishing.get_video_job_by_draft(draft_id) do
      nil -> []
      job -> [job]
    end
  end
end
