defmodule ContentForge.Jobs.ImageGeneratorTest do
  use ContentForge.DataCase, async: false
  use Oban.Testing, repo: ContentForge.Repo

  import ExUnit.CaptureLog

  alias ContentForge.ContentGeneration
  alias ContentForge.Jobs.ImageGenerator
  alias ContentForge.Products

  @media_forge_key :media_forge
  @image_gen_key :image_generator
  @stub_key ContentForge.MediaForge

  setup do
    original_mf = Application.get_env(:content_forge, @media_forge_key, [])
    original_ig = Application.get_env(:content_forge, @image_gen_key, [])

    on_exit(fn ->
      Application.put_env(:content_forge, @media_forge_key, original_mf)
      Application.put_env(:content_forge, @image_gen_key, original_ig)
    end)

    Application.put_env(:content_forge, @media_forge_key,
      base_url: "http://media-forge.test",
      secret: "test-secret",
      req_options: [plug: {Req.Test, @stub_key}]
    )

    Application.put_env(:content_forge, @image_gen_key,
      poll_interval_ms: 0,
      poll_max_attempts: 5
    )

    {:ok, product} =
      Products.create_product(%{name: "Test Product", voice_profile: "professional"})

    {:ok, draft} =
      ContentGeneration.create_draft(%{
        product_id: product.id,
        content: "A social post about our new gadget",
        platform: "twitter",
        content_type: "post",
        angle: "educational",
        generating_model: "claude",
        status: "ranked"
      })

    %{product: product, draft: draft}
  end

  describe "synchronous Media Forge response" do
    test "persists the returned image_url onto the draft", %{draft: draft} do
      Req.Test.stub(@stub_key, fn conn ->
        assert conn.request_path == "/api/v1/generation/images"
        Req.Test.json(conn, %{"image_url" => "https://cdn.example/img/sync.png"})
      end)

      assert {:ok, "https://cdn.example/img/sync.png"} =
               perform_job(ImageGenerator, %{"draft_id" => draft.id})

      updated = ContentGeneration.get_draft!(draft.id)
      assert updated.image_url == "https://cdn.example/img/sync.png"
    end
  end

  describe "asynchronous Media Forge response" do
    test "polls job status until done and persists the image_url", %{draft: draft} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(@stub_key, fn conn ->
        Agent.update(counter, &(&1 + 1))
        call_number = Agent.get(counter, & &1)
        handle_async_call(conn, call_number)
      end)

      assert {:ok, "https://cdn.example/img/async.png"} =
               perform_job(ImageGenerator, %{"draft_id" => draft.id})

      updated = ContentGeneration.get_draft!(draft.id)
      assert updated.image_url == "https://cdn.example/img/async.png"

      # 1 POST to /generation/images + 3 GETs to /jobs/:id (pending, running, done)
      assert Agent.get(counter, & &1) == 4
    end

    test "stops polling, marks the draft blocked, and cancels when the job reports failure",
         %{draft: draft} do
      Req.Test.stub(@stub_key, fn conn ->
        respond_failed_async(conn)
      end)

      log =
        capture_log(fn ->
          assert {:cancel, reason} =
                   perform_job(ImageGenerator, %{"draft_id" => draft.id})

          assert reason =~ "Media Forge image job failed"
          assert reason =~ "provider timed out"
        end)

      assert log =~ "failed"

      updated = ContentGeneration.get_draft!(draft.id)
      assert updated.image_url == nil
      assert updated.status == "blocked"
      assert updated.error =~ "provider timed out"
    end

    test "returns an error after exhausting poll_max_attempts without a terminal state",
         %{draft: draft} do
      Req.Test.stub(@stub_key, fn conn ->
        respond_always_pending(conn)
      end)

      assert {:error, :media_forge_job_poll_timeout} =
               perform_job(ImageGenerator, %{"draft_id" => draft.id})

      updated = ContentGeneration.get_draft!(draft.id)
      assert updated.image_url == nil
    end
  end

  describe "missing secret" do
    test "logs Media Forge unavailable, returns {:ok, :skipped}, and leaves image_url nil",
         %{draft: draft} do
      config = Application.get_env(:content_forge, @media_forge_key)
      Application.put_env(:content_forge, @media_forge_key, Keyword.put(config, :secret, nil))

      test_pid = self()

      Req.Test.stub(@stub_key, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no HTTP should be issued when Media Forge is unavailable"
      end)

      log =
        capture_log(fn ->
          assert {:ok, :skipped} = perform_job(ImageGenerator, %{"draft_id" => draft.id})
        end)

      refute_received :unexpected_http
      assert log =~ "Media Forge unavailable"

      updated = ContentGeneration.get_draft!(draft.id)
      assert updated.image_url == nil
    end
  end

  describe "error classification" do
    test "4xx permanent error cancels the job", %{draft: draft} do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(422, JSON.encode!(%{"error" => "invalid prompt"}))
      end)

      log =
        capture_log(fn ->
          assert {:cancel, _reason} = perform_job(ImageGenerator, %{"draft_id" => draft.id})
        end)

      assert log =~ "422" or log =~ "invalid prompt"

      updated = ContentGeneration.get_draft!(draft.id)
      assert updated.image_url == nil
    end

    test "5xx transient error returns {:error, _} so Oban retries", %{draft: draft} do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, JSON.encode!(%{"error" => "overloaded"}))
      end)

      log =
        capture_log(fn ->
          assert {:error, {:transient, 503, _body}} =
                   perform_job(ImageGenerator, %{"draft_id" => draft.id})
        end)

      assert log =~ "transient" or log =~ "503"

      updated = ContentGeneration.get_draft!(draft.id)
      assert updated.image_url == nil
    end
  end

  describe "draft filters" do
    test "non-social-post drafts are skipped without issuing an HTTP request",
         %{product: product} do
      {:ok, blog} =
        ContentGeneration.create_draft(%{
          product_id: product.id,
          content: "A long blog post",
          platform: "blog",
          content_type: "blog",
          generating_model: "claude",
          status: "ranked"
        })

      test_pid = self()

      Req.Test.stub(@stub_key, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no HTTP should be issued for non-post drafts"
      end)

      assert {:ok, :skipped_non_post} = perform_job(ImageGenerator, %{"draft_id" => blog.id})
      refute_received :unexpected_http
    end

    test "drafts that already have an image_url are not regenerated", %{draft: draft} do
      {:ok, draft} =
        ContentGeneration.update_draft(draft, %{image_url: "https://cdn.example/existing.png"})

      test_pid = self()

      Req.Test.stub(@stub_key, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no HTTP should be issued when image_url is already set"
      end)

      assert {:ok, :already_attached} =
               perform_job(ImageGenerator, %{"draft_id" => draft.id})

      refute_received :unexpected_http
    end
  end

  describe "process_all_social_posts" do
    test "enqueues children on :content_generation queue (no :image_generation override)",
         %{product: product, draft: draft} do
      {:ok, _other} =
        ContentGeneration.create_draft(%{
          product_id: product.id,
          content: "Another post",
          platform: "linkedin",
          content_type: "post",
          generating_model: "claude",
          status: "ranked"
        })

      assert {:ok, %{enqueued: enqueued}} =
               perform_job(ImageGenerator, %{"product_id" => product.id})

      assert enqueued >= 2

      assert_enqueued(
        worker: ContentForge.Jobs.ImageGenerator,
        queue: :content_generation,
        args: %{"draft_id" => draft.id}
      )

      refute_enqueued(queue: :image_generation)
    end
  end

  describe "coverage fill: alternate sync response shapes" do
    test "sync response with top-level \"url\" key persists it", %{draft: draft} do
      Req.Test.stub(@stub_key, fn conn ->
        Req.Test.json(conn, %{"url" => "https://cdn.example/url-key.png"})
      end)

      assert {:ok, "https://cdn.example/url-key.png"} =
               perform_job(ImageGenerator, %{"draft_id" => draft.id})

      assert ContentGeneration.get_draft!(draft.id).image_url ==
               "https://cdn.example/url-key.png"
    end

    test "sync response with nested result.image_url persists it",
         %{draft: draft} do
      Req.Test.stub(@stub_key, fn conn ->
        Req.Test.json(conn, %{
          "result" => %{"image_url" => "https://cdn.example/nested.png"}
        })
      end)

      assert {:ok, "https://cdn.example/nested.png"} =
               perform_job(ImageGenerator, %{"draft_id" => draft.id})
    end

    test "unrecognized sync body (no url, no jobId) cancels the job",
         %{draft: draft} do
      Req.Test.stub(@stub_key, fn conn ->
        Req.Test.json(conn, %{"status" => "accepted", "metadata" => %{"provider" => "flux"}})
      end)

      log =
        capture_log(fn ->
          assert {:cancel, "unrecognized Media Forge response"} =
                   perform_job(ImageGenerator, %{"draft_id" => draft.id})
        end)

      assert log =~ "unrecognized"
      assert ContentGeneration.get_draft!(draft.id).image_url == nil
    end
  end

  describe "coverage fill: error classification branches" do
    test "unexpected-status error from Media Forge cancels the job", %{draft: draft} do
      Req.Test.stub(@stub_key, fn conn ->
        # 304 reaches classify/1 through MediaForge and becomes :unexpected_status
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(304, "")
      end)

      log =
        capture_log(fn ->
          assert {:cancel, reason} =
                   perform_job(ImageGenerator, %{"draft_id" => draft.id})

          assert reason =~ "unexpected HTTP status 304"
        end)

      assert log =~ "unexpected status 304"
      assert ContentGeneration.get_draft!(draft.id).image_url == nil
    end

    test "generic error tuple from MediaForge propagates as {:error, reason}",
         %{draft: draft} do
      # A redirect loop yields %Req.TooManyRedirectsError{}, which is neither a
      # TransportError nor a classified HTTP status. MediaForge's classify/1
      # passes it through its generic catch-all, and ImageGenerator's
      # handle_generate_response/2 catch-all should forward it as {:error, _}.
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_resp_header(
          "location",
          "https://media-forge.test/api/v1/generation/images"
        )
        |> Plug.Conn.resp(302, "")
      end)

      log =
        capture_log(fn ->
          assert {:error, %Req.TooManyRedirectsError{}} =
                   perform_job(ImageGenerator, %{"draft_id" => draft.id})
        end)

      assert log =~ "unexpected Media Forge error"
      assert ContentGeneration.get_draft!(draft.id).image_url == nil
    end
  end

  describe "coverage fill: polling branches" do
    test "poll observes a late :not_configured from Media Forge and downgrades",
         %{draft: draft} do
      # The initial POST returns a jobId so the worker enters the polling
      # path. The stub clears the Media Forge secret as a side effect of the
      # POST response, so the subsequent MediaForge.get_job/1 short-circuits
      # to {:error, :not_configured} without any HTTP call. This matches the
      # real-world "secret removed mid-job" condition.
      config = Application.get_env(:content_forge, @media_forge_key)

      Req.Test.stub(@stub_key, fn conn ->
        case conn.request_path do
          "/api/v1/generation/images" ->
            Application.put_env(
              :content_forge,
              @media_forge_key,
              Keyword.put(config, :secret, nil)
            )

            Req.Test.json(conn, %{"jobId" => "gen-late-skip"})

          path ->
            flunk("expected no HTTP after secret cleared; got #{path}")
        end
      end)

      log =
        capture_log(fn ->
          assert {:ok, :skipped} =
                   perform_job(ImageGenerator, %{"draft_id" => draft.id})
        end)

      assert log =~ "Media Forge became unavailable while polling"
      assert ContentGeneration.get_draft!(draft.id).image_url == nil
    end

    test "poll \"done\" response with no extractable URL cancels the job",
         %{draft: draft} do
      Req.Test.stub(@stub_key, fn conn ->
        case conn.request_path do
          "/api/v1/generation/images" ->
            Req.Test.json(conn, %{"jobId" => "gen-no-url"})

          "/api/v1/jobs/gen-no-url" ->
            # "done" but no image url anywhere in the body
            Req.Test.json(conn, %{
              "id" => "gen-no-url",
              "status" => "done",
              "result" => %{"metadata" => %{"provider" => "flux"}}
            })
        end
      end)

      log =
        capture_log(fn ->
          assert {:cancel, "Media Forge reported done without an image url"} =
                   perform_job(ImageGenerator, %{"draft_id" => draft.id})
        end)

      assert log =~ "reported done but no image url"
      updated = ContentGeneration.get_draft!(draft.id)
      assert updated.image_url == nil
      assert updated.status == "blocked"
    end

    test "poll done response with top-level image_url persists it", %{draft: draft} do
      Req.Test.stub(@stub_key, fn conn ->
        case conn.request_path do
          "/api/v1/generation/images" ->
            Req.Test.json(conn, %{"jobId" => "gen-top-image-url"})

          "/api/v1/jobs/gen-top-image-url" ->
            Req.Test.json(conn, %{
              "id" => "gen-top-image-url",
              "status" => "completed",
              "image_url" => "https://cdn.example/top-image-url.png"
            })
        end
      end)

      assert {:ok, "https://cdn.example/top-image-url.png"} =
               perform_job(ImageGenerator, %{"draft_id" => draft.id})
    end

    test "poll done response with result.url (not image_url) persists it",
         %{draft: draft} do
      Req.Test.stub(@stub_key, fn conn ->
        case conn.request_path do
          "/api/v1/generation/images" ->
            Req.Test.json(conn, %{"jobId" => "gen-result-url"})

          "/api/v1/jobs/gen-result-url" ->
            Req.Test.json(conn, %{
              "id" => "gen-result-url",
              "status" => "succeeded",
              "result" => %{"url" => "https://cdn.example/result-url.png"}
            })
        end
      end)

      assert {:ok, "https://cdn.example/result-url.png"} =
               perform_job(ImageGenerator, %{"draft_id" => draft.id})
    end

    test "poll returns a non-:not_configured error tuple and propagates it",
         %{draft: draft} do
      Req.Test.stub(@stub_key, fn conn ->
        case conn.request_path do
          "/api/v1/generation/images" ->
            Req.Test.json(conn, %{"jobId" => "gen-poll-err"})

          "/api/v1/jobs/gen-poll-err" ->
            # 503 during polling -> MediaForge returns {:error, {:transient, 503, body}}
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(503, JSON.encode!(%{"error" => "overloaded"}))
        end
      end)

      log =
        capture_log(fn ->
          assert {:error, {:transient, 503, _body}} =
                   perform_job(ImageGenerator, %{"draft_id" => draft.id})
        end)

      assert log =~ "poll of Media Forge job"
      assert ContentGeneration.get_draft!(draft.id).image_url == nil
    end
  end

  # --- async stub helpers ----------------------------------------------------

  defp handle_async_call(conn, 1) do
    # initial POST /api/v1/generation/images returns a job id
    assert conn.request_path == "/api/v1/generation/images"
    Req.Test.json(conn, %{"jobId" => "gen-async-1", "status" => "pending"})
  end

  defp handle_async_call(conn, 2) do
    assert conn.method == "GET"
    assert conn.request_path == "/api/v1/jobs/gen-async-1"
    Req.Test.json(conn, %{"id" => "gen-async-1", "status" => "pending"})
  end

  defp handle_async_call(conn, 3) do
    Req.Test.json(conn, %{"id" => "gen-async-1", "status" => "running", "progress" => 0.5})
  end

  defp handle_async_call(conn, 4) do
    Req.Test.json(conn, %{
      "id" => "gen-async-1",
      "status" => "done",
      "result" => %{"image_url" => "https://cdn.example/img/async.png"}
    })
  end

  defp respond_failed_async(conn) do
    case {conn.method, conn.request_path} do
      {"POST", "/api/v1/generation/images"} ->
        Req.Test.json(conn, %{"jobId" => "gen-fail-1", "status" => "pending"})

      {"GET", "/api/v1/jobs/gen-fail-1"} ->
        Req.Test.json(conn, %{
          "id" => "gen-fail-1",
          "status" => "failed",
          "error" => "provider timed out"
        })
    end
  end

  defp respond_always_pending(conn) do
    case {conn.method, conn.request_path} do
      {"POST", "/api/v1/generation/images"} ->
        Req.Test.json(conn, %{"jobId" => "gen-pending-1", "status" => "pending"})

      {"GET", "/api/v1/jobs/gen-pending-1"} ->
        Req.Test.json(conn, %{"id" => "gen-pending-1", "status" => "pending"})
    end
  end
end
