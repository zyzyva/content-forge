defmodule ContentForge.Jobs.VideoProducerTest do
  use ContentForge.DataCase, async: false
  use Oban.Testing, repo: ContentForge.Repo

  import ExUnit.CaptureLog

  alias ContentForge.ContentGeneration
  alias ContentForge.Jobs.VideoProducer
  alias ContentForge.Products
  alias ContentForge.Publishing

  @media_forge_key :media_forge
  @video_producer_key :video_producer
  @stub_key ContentForge.MediaForge

  setup do
    original_mf = Application.get_env(:content_forge, @media_forge_key, [])
    original_vp = Application.get_env(:content_forge, @video_producer_key, [])

    on_exit(fn ->
      Application.put_env(:content_forge, @media_forge_key, original_mf)
      Application.put_env(:content_forge, @video_producer_key, original_vp)
    end)

    Application.put_env(:content_forge, @media_forge_key,
      base_url: "http://media-forge.test",
      secret: "test-secret",
      req_options: [plug: {Req.Test, @stub_key}]
    )

    Application.put_env(:content_forge, @video_producer_key,
      poll_interval_ms: 0,
      poll_max_attempts: 5
    )

    publishing_targets = %{
      "elevenlabs" => %{"api_key" => "el-key", "voice_id" => "voice-123"},
      "screen_recording" => %{"enabled" => true, "duration_seconds" => 10},
      "heygen" => %{"api_key" => "hg-key", "avatar_id" => "avatar-1"},
      "remotion" => %{"enabled" => true},
      "youtube" => %{"enabled" => true, "access_token" => "yt-token"}
    }

    {:ok, product} =
      Products.create_product(%{
        name: "Test Product",
        voice_profile: "professional",
        site_url: "https://example.com",
        publishing_targets: publishing_targets
      })

    {:ok, draft} =
      ContentGeneration.create_draft(%{
        product_id: product.id,
        content: "A great script for a short explainer video",
        platform: "youtube",
        content_type: "video_script",
        generating_model: "claude",
        status: "approved"
      })

    {:ok, video_job} =
      Publishing.create_video_job(%{
        draft_id: draft.id,
        product_id: product.id,
        feature_flag: true
      })

    %{product: product, draft: draft, video_job: video_job}
  end

  describe "step 5 replaces local FFmpeg simulation with Media Forge" do
    test "sync success persists the returned R2 key and transitions the job",
         %{video_job: video_job} do
      Req.Test.stub(@stub_key, fn conn ->
        case conn.request_path do
          "/api/v1/video/render" ->
            assert conn.method == "POST"
            Req.Test.json(conn, %{"output_r2_key" => "videos/final-sync.mp4"})

          _other ->
            Req.Test.json(conn, %{})
        end
      end)

      assert :ok = perform_job(VideoProducer, %{"video_job_id" => video_job.id})

      updated = Publishing.get_video_job(video_job.id)
      assert updated.per_step_r2_keys["final"] == "videos/final-sync.mp4"
      # Full pipeline completes through the existing YouTube simulation.
      assert updated.status == "uploaded"
    end

    test "async success is resolved by polling job status", %{video_job: video_job} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(@stub_key, fn conn ->
        Agent.update(counter, &(&1 + 1))
        call_number = Agent.get(counter, & &1)
        handle_async_call(conn, call_number)
      end)

      assert :ok = perform_job(VideoProducer, %{"video_job_id" => video_job.id})

      updated = Publishing.get_video_job(video_job.id)
      assert updated.per_step_r2_keys["final"] == "videos/final-async.mp4"
      assert updated.status == "uploaded"

      # POST /video/render + 2 polls (pending, done)
      assert Agent.get(counter, & &1) == 3
    end
  end

  describe "Media Forge downgrades and failures" do
    test "missing secret leaves the job at assembled with an error message",
         %{video_job: video_job} do
      config = Application.get_env(:content_forge, @media_forge_key)
      Application.put_env(:content_forge, @media_forge_key, Keyword.put(config, :secret, nil))

      test_pid = self()

      Req.Test.stub(@stub_key, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no HTTP expected when Media Forge is unavailable"
      end)

      log =
        capture_log(fn ->
          assert :ok = perform_job(VideoProducer, %{"video_job_id" => video_job.id})
        end)

      refute_received :unexpected_http
      assert log =~ "Media Forge unavailable"

      updated = Publishing.get_video_job(video_job.id)
      assert updated.status == "assembled"
      assert updated.error =~ "Media Forge unavailable"
      refute Map.has_key?(updated.per_step_r2_keys || %{}, "final")
    end

    test "permanent 4xx error marks the job failed", %{video_job: video_job} do
      Req.Test.stub(@stub_key, fn conn ->
        case conn.request_path do
          "/api/v1/video/render" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(422, JSON.encode!(%{"error" => "invalid source"}))

          _ ->
            Req.Test.json(conn, %{})
        end
      end)

      log =
        capture_log(fn ->
          assert {:cancel, reason} =
                   perform_job(VideoProducer, %{"video_job_id" => video_job.id})

          assert reason =~ "422" or reason =~ "invalid"
        end)

      assert log =~ "422" or log =~ "rejected"

      updated = Publishing.get_video_job(video_job.id)
      assert updated.status == "failed"
      assert updated.error =~ "422" or updated.error =~ "rejected"
      refute Map.has_key?(updated.per_step_r2_keys || %{}, "final")
    end

    test "transient 5xx error returns {:error, _} so Oban retries",
         %{video_job: video_job} do
      Req.Test.stub(@stub_key, fn conn ->
        case conn.request_path do
          "/api/v1/video/render" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(503, JSON.encode!(%{"error" => "overloaded"}))

          _ ->
            Req.Test.json(conn, %{})
        end
      end)

      log =
        capture_log(fn ->
          assert {:error, _reason} =
                   perform_job(VideoProducer, %{"video_job_id" => video_job.id})
        end)

      assert log =~ "transient" or log =~ "503"

      updated = Publishing.get_video_job(video_job.id)
      # Status should NOT be "failed" (transient, Oban will retry).
      refute updated.status == "failed"
      # Status should NOT be "encoded"/"uploaded" (render did not complete).
      refute updated.status == "encoded"
      refute updated.status == "uploaded"
      refute Map.has_key?(updated.per_step_r2_keys || %{}, "final")
    end
  end

  # --- async stub helpers ----------------------------------------------------

  defp handle_async_call(conn, 1) do
    assert conn.request_path == "/api/v1/video/render"
    assert conn.method == "POST"
    Req.Test.json(conn, %{"jobId" => "render-async-1"})
  end

  defp handle_async_call(conn, 2) do
    assert conn.method == "GET"
    assert conn.request_path == "/api/v1/jobs/render-async-1"
    Req.Test.json(conn, %{"id" => "render-async-1", "status" => "pending"})
  end

  defp handle_async_call(conn, 3) do
    Req.Test.json(conn, %{
      "id" => "render-async-1",
      "status" => "done",
      "result" => %{"output_r2_key" => "videos/final-async.mp4"}
    })
  end
end
