defmodule ContentForge.Publishing.PromoteScriptTest do
  use ContentForge.DataCase, async: false
  use Oban.Testing, repo: ContentForge.Repo

  alias ContentForge.ContentGeneration
  alias ContentForge.Jobs.VideoProducer
  alias ContentForge.Products
  alias ContentForge.Publishing
  alias ContentForge.Publishing.VideoJob

  defp create_product! do
    {:ok, product} = Products.create_product(%{name: "P", voice_profile: "professional"})
    product
  end

  defp create_script!(product, attrs \\ %{}) do
    defaults = %{
      product_id: product.id,
      content: "a video script",
      platform: "youtube",
      content_type: "video_script",
      generating_model: "claude",
      status: "ranked"
    }

    {:ok, draft} = ContentGeneration.create_draft(Map.merge(defaults, attrs))
    draft
  end

  describe "promote_script/2 at/above threshold" do
    test "creates a VideoJob with promoted_via_override: false when score >= threshold" do
      product = create_product!()
      script = create_script!(product)

      assert {:ok, %VideoJob{} = job} =
               Publishing.promote_script(script.id,
                 score: 7.5,
                 threshold: 6.0,
                 enqueue_producer: false
               )

      assert job.draft_id == script.id
      assert job.status == "script_approved"
      assert job.promoted_via_override == false
      assert job.promoted_score == 7.5
      assert job.promoted_threshold == 6.0

      assert ContentGeneration.get_draft!(script.id).status == "approved"
    end

    test "enqueues VideoProducer by default" do
      product = create_product!()
      script = create_script!(product)

      assert {:ok, job} =
               Publishing.promote_script(script.id, score: 7.0, threshold: 6.0)

      assert_enqueued(
        worker: VideoProducer,
        args: %{"video_job_id" => job.id}
      )
    end
  end

  describe "promote_script/2 below threshold (override)" do
    test "sets promoted_via_override: true + records score + threshold" do
      product = create_product!()
      script = create_script!(product)

      assert {:ok, %VideoJob{} = job} =
               Publishing.promote_script(script.id,
                 score: 4.5,
                 threshold: 6.0,
                 enqueue_producer: false
               )

      assert job.promoted_via_override == true
      assert job.promoted_score == 4.5
      assert job.promoted_threshold == 6.0

      assert ContentGeneration.get_draft!(script.id).status == "approved"
    end

    test "sets promoted_via_override: true when score is nil (never scored)" do
      product = create_product!()
      script = create_script!(product)

      assert {:ok, job} =
               Publishing.promote_script(script.id,
                 score: nil,
                 threshold: 6.0,
                 enqueue_producer: false
               )

      assert job.promoted_via_override == true
      assert job.promoted_score == nil
    end
  end

  describe "promote_script/2 reads from config when threshold/score omitted" do
    test "uses script_gate_threshold() default 6.0 and composite score lookup" do
      product = create_product!()
      script = create_script!(product)

      # No scores recorded -> composite_score is nil -> override.
      assert {:ok, job} =
               Publishing.promote_script(script.id, enqueue_producer: false)

      assert job.promoted_via_override == true
      assert job.promoted_threshold == 6.0
    end

    test "respects :script_gate config override" do
      original = Application.get_env(:content_forge, :script_gate, [])
      Application.put_env(:content_forge, :script_gate, threshold: 2.0)
      on_exit(fn -> Application.put_env(:content_forge, :script_gate, original) end)

      product = create_product!()
      script = create_script!(product)

      assert {:ok, job} =
               Publishing.promote_script(script.id,
                 score: 3.0,
                 enqueue_producer: false
               )

      assert job.promoted_threshold == 2.0
      assert job.promoted_via_override == false
    end
  end

  describe "promote_script/2 errors" do
    test "returns {:error, :draft_not_found} for an unknown id" do
      assert {:error, :draft_not_found} =
               Publishing.promote_script("00000000-0000-0000-0000-000000000000",
                 enqueue_producer: false
               )
    end
  end
end
