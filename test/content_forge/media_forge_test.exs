defmodule ContentForge.MediaForgeTest do
  use ExUnit.Case, async: false

  alias ContentForge.MediaForge

  @config_key :media_forge
  @stub_key ContentForge.MediaForge

  setup context do
    original = Application.get_env(:content_forge, @config_key, [])

    on_exit(fn ->
      Application.put_env(:content_forge, @config_key, original)
    end)

    base = [
      base_url: "http://media-forge.test",
      secret: "test-secret",
      req_options: [plug: {Req.Test, @stub_key}]
    ]

    Application.put_env(:content_forge, @config_key, base)
    Map.put(context, :config, base)
  end

  describe "status/0" do
    test "returns :ok when a secret is configured" do
      assert MediaForge.status() == :ok
    end

    test "returns :not_configured when the secret is missing" do
      config = Application.get_env(:content_forge, @config_key)
      Application.put_env(:content_forge, @config_key, Keyword.delete(config, :secret))

      assert MediaForge.status() == :not_configured
    end

    test "returns :not_configured when the secret is an empty string" do
      config = Application.get_env(:content_forge, @config_key)
      Application.put_env(:content_forge, @config_key, Keyword.put(config, :secret, ""))

      assert MediaForge.status() == :not_configured
    end
  end

  describe "missing secret" do
    test "every call returns {:error, :not_configured} without issuing an HTTP request" do
      test_pid = self()
      config = Application.get_env(:content_forge, @config_key)
      Application.put_env(:content_forge, @config_key, Keyword.put(config, :secret, nil))

      Req.Test.stub(@stub_key, fn _conn ->
        send(test_pid, :unexpected_http_call)
        raise "Media Forge client must not hit HTTP when not configured"
      end)

      assert {:error, :not_configured} = MediaForge.probe(%{path: "/foo.mp4"})
      assert {:error, :not_configured} = MediaForge.enqueue_video_normalize(%{})
      assert {:error, :not_configured} = MediaForge.enqueue_video_render(%{})
      assert {:error, :not_configured} = MediaForge.enqueue_video_trim(%{})
      assert {:error, :not_configured} = MediaForge.enqueue_video_batch(%{})
      assert {:error, :not_configured} = MediaForge.enqueue_image_process(%{})
      assert {:error, :not_configured} = MediaForge.enqueue_image_render(%{})
      assert {:error, :not_configured} = MediaForge.enqueue_image_batch(%{})
      assert {:error, :not_configured} = MediaForge.generate_images(%{})
      assert {:error, :not_configured} = MediaForge.compare_generations(%{})
      assert {:error, :not_configured} = MediaForge.get_job("job-1")
      assert {:error, :not_configured} = MediaForge.cancel_job("job-1")

      refute_received :unexpected_http_call
    end
  end

  describe "authentication header" do
    test "attaches X-MediaForge-Secret on every outbound request" do
      Req.Test.stub(@stub_key, fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-mediaforge-secret") == ["test-secret"]
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert {:ok, %{"ok" => true}} = MediaForge.probe(%{path: "/foo.mp4"})
    end
  end

  describe "error classification" do
    test "5xx response returns a transient error tuple with status and body" do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, JSON.encode!(%{"error" => "overloaded"}))
      end)

      assert {:error, {:transient, 503, %{"error" => "overloaded"}}} =
               MediaForge.probe(%{path: "/foo.mp4"})
    end

    test "4xx response returns a permanent http_error tuple with status and body" do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(422, JSON.encode!(%{"error" => "invalid input"}))
      end)

      assert {:error, {:http_error, 422, %{"error" => "invalid input"}}} =
               MediaForge.probe(%{path: "/bad.mp4"})
    end

    test "transport timeout is classified as transient" do
      Req.Test.stub(@stub_key, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, {:transient, :timeout, _}} = MediaForge.probe(%{path: "/slow.mp4"})
    end

    test "connection refusal is classified as transient network failure" do
      Req.Test.stub(@stub_key, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, {:transient, :network, :econnrefused}} =
               MediaForge.probe(%{path: "/foo.mp4"})
    end

    test "classified errors do not retry inside the client" do
      call_counter = :counters.new(1, [])

      Req.Test.stub(@stub_key, fn conn ->
        :counters.add(call_counter, 1, 1)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, JSON.encode!(%{"error" => "boom"}))
      end)

      assert {:error, {:transient, 500, _}} = MediaForge.probe(%{path: "/foo.mp4"})
      assert :counters.get(call_counter, 1) == 1
    end
  end

  describe "video enqueue functions" do
    test "enqueue_video_normalize posts to /api/v1/video/normalize and returns the job id" do
      Req.Test.stub(@stub_key, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/v1/video/normalize"
        Req.Test.json(conn, %{"jobId" => "job-normalize-1"})
      end)

      assert {:ok, %{"jobId" => "job-normalize-1"}} =
               MediaForge.enqueue_video_normalize(%{source: "s3://bucket/a.mp4"})
    end

    test "enqueue_video_render posts to /api/v1/video/render" do
      Req.Test.stub(@stub_key, fn conn ->
        assert conn.request_path == "/api/v1/video/render"
        Req.Test.json(conn, %{"jobId" => "job-render-1"})
      end)

      assert {:ok, %{"jobId" => "job-render-1"}} =
               MediaForge.enqueue_video_render(%{timeline: []})
    end

    test "enqueue_video_trim posts to /api/v1/video/trim" do
      Req.Test.stub(@stub_key, fn conn ->
        assert conn.request_path == "/api/v1/video/trim"
        Req.Test.json(conn, %{"jobId" => "job-trim-1"})
      end)

      assert {:ok, %{"jobId" => "job-trim-1"}} = MediaForge.enqueue_video_trim(%{start: 0})
    end

    test "enqueue_video_batch posts to /api/v1/video/batch" do
      Req.Test.stub(@stub_key, fn conn ->
        assert conn.request_path == "/api/v1/video/batch"
        Req.Test.json(conn, %{"jobId" => "job-batch-1"})
      end)

      assert {:ok, %{"jobId" => "job-batch-1"}} = MediaForge.enqueue_video_batch(%{items: []})
    end
  end

  describe "image enqueue functions" do
    test "enqueue_image_process posts to /api/v1/image/process" do
      Req.Test.stub(@stub_key, fn conn ->
        assert conn.request_path == "/api/v1/image/process"
        Req.Test.json(conn, %{"jobId" => "job-proc-1"})
      end)

      assert {:ok, %{"jobId" => "job-proc-1"}} =
               MediaForge.enqueue_image_process(%{source: "s3://bucket/img.png"})
    end

    test "enqueue_image_render posts to /api/v1/image/render" do
      Req.Test.stub(@stub_key, fn conn ->
        assert conn.request_path == "/api/v1/image/render"
        Req.Test.json(conn, %{"jobId" => "job-render-img"})
      end)

      assert {:ok, %{"jobId" => "job-render-img"}} =
               MediaForge.enqueue_image_render(%{layers: []})
    end

    test "enqueue_image_batch posts to /api/v1/image/batch" do
      Req.Test.stub(@stub_key, fn conn ->
        assert conn.request_path == "/api/v1/image/batch"
        Req.Test.json(conn, %{"jobId" => "job-batch-img"})
      end)

      assert {:ok, %{"jobId" => "job-batch-img"}} =
               MediaForge.enqueue_image_batch(%{items: []})
    end
  end

  describe "generation endpoints" do
    test "generate_images posts to /api/v1/generation/images and returns the provider map" do
      Req.Test.stub(@stub_key, fn conn ->
        assert conn.request_path == "/api/v1/generation/images"
        Req.Test.json(conn, %{"jobId" => "gen-1", "provider" => "replicate"})
      end)

      assert {:ok, %{"jobId" => "gen-1", "provider" => "replicate"}} =
               MediaForge.generate_images(%{prompt: "a cat"})
    end

    test "generate_images can return a synchronous result without a job id" do
      Req.Test.stub(@stub_key, fn conn ->
        Req.Test.json(conn, %{"images" => [%{"url" => "https://cdn/a.png"}]})
      end)

      assert {:ok, %{"images" => [%{"url" => "https://cdn/a.png"}]}} =
               MediaForge.generate_images(%{prompt: "a cat"})
    end

    test "compare_generations posts to /api/v1/generation/compare" do
      Req.Test.stub(@stub_key, fn conn ->
        assert conn.request_path == "/api/v1/generation/compare"
        Req.Test.json(conn, %{"winner" => "a"})
      end)

      assert {:ok, %{"winner" => "a"}} = MediaForge.compare_generations(%{a: "x", b: "y"})
    end
  end

  describe "get_job/1" do
    test "performs a GET to /api/v1/jobs/:id and returns the status map verbatim" do
      Req.Test.stub(@stub_key, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v1/jobs/job-abc"
        Req.Test.json(conn, %{"id" => "job-abc", "status" => "running", "progress" => 0.42})
      end)

      assert {:ok, %{"id" => "job-abc", "status" => "running", "progress" => 0.42}} =
               MediaForge.get_job("job-abc")
    end
  end

  describe "cancel_job/1" do
    test "posts to /api/v1/jobs/:id/cancel and returns the acknowledgement map" do
      Req.Test.stub(@stub_key, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/v1/jobs/job-xyz/cancel"
        Req.Test.json(conn, %{"id" => "job-xyz", "cancelled" => true})
      end)

      assert {:ok, %{"id" => "job-xyz", "cancelled" => true}} = MediaForge.cancel_job("job-xyz")
    end
  end
end
