defmodule ContentForge.Jobs.AssetVideoProcessorTest do
  use ContentForge.DataCase, async: false
  use Oban.Testing, repo: ContentForge.Repo

  import ExUnit.CaptureLog

  alias ContentForge.Jobs.AssetVideoProcessor
  alias ContentForge.ProductAssets
  alias ContentForge.Products

  @media_forge_key :media_forge
  @processor_key :asset_video_processor
  @stub_key ContentForge.MediaForge

  setup do
    original_mf = Application.get_env(:content_forge, @media_forge_key, [])
    original_proc = Application.get_env(:content_forge, @processor_key, [])

    on_exit(fn ->
      Application.put_env(:content_forge, @media_forge_key, original_mf)
      Application.put_env(:content_forge, @processor_key, original_proc)
    end)

    Application.put_env(:content_forge, @media_forge_key,
      base_url: "http://media-forge.test",
      secret: "test-secret",
      req_options: [plug: {Req.Test, @stub_key}]
    )

    Application.put_env(:content_forge, @processor_key,
      poll_interval_ms: 0,
      poll_max_attempts: 5
    )

    {:ok, product} =
      Products.create_product(%{name: "Test Product", voice_profile: "professional"})

    {:ok, asset} =
      ProductAssets.create_asset(%{
        product_id: product.id,
        storage_key: "products/#{product.id}/assets/abc/demo.mp4",
        media_type: "video",
        filename: "demo.mp4",
        mime_type: "video/mp4",
        byte_size: 10_000_000,
        uploaded_at: DateTime.utc_now()
      })

    %{product: product, asset: asset}
  end

  describe "synchronous happy path" do
    test "persists duration_ms, dimensions, normalized + poster keys", %{asset: asset} do
      Req.Test.stub(@stub_key, fn conn ->
        assert conn.request_path == "/api/v1/video/normalize"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        {:ok, decoded} = JSON.decode(body)

        assert decoded["source_key"] == asset.storage_key
        assert "probe" in decoded["transforms"]
        assert "normalize" in decoded["transforms"]
        assert "poster" in decoded["transforms"]
        assert decoded["normalize"]["video_codec"] == "h264"
        assert decoded["normalize"]["audio_codec"] == "aac"

        Req.Test.json(conn, %{
          "result" => %{
            "width" => 1920,
            "height" => 1080,
            "duration_ms" => 12_345,
            "normalized_storage_key" => "products/videos/demo-normalized.mp4",
            "poster_storage_key" => "products/videos/demo-poster.jpg"
          }
        })
      end)

      assert {:ok, _} = perform_job(AssetVideoProcessor, %{"asset_id" => asset.id})

      updated = ProductAssets.get_asset!(asset.id)
      assert updated.status == "processed"
      assert updated.width == 1920
      assert updated.height == 1080
      assert updated.duration_ms == 12_345
      assert updated.normalized_storage_key == "products/videos/demo-normalized.mp4"
      assert updated.thumbnail_storage_key == "products/videos/demo-poster.jpg"
      assert updated.error == nil
    end

    test "accepts duration_seconds and converts to duration_ms", %{asset: asset} do
      Req.Test.stub(@stub_key, fn conn ->
        Req.Test.json(conn, %{
          "result" => %{
            "width" => 1280,
            "height" => 720,
            "duration_seconds" => 42.5,
            "normalized_storage_key" => "k",
            "poster_storage_key" => "p"
          }
        })
      end)

      assert {:ok, _} = perform_job(AssetVideoProcessor, %{"asset_id" => asset.id})

      updated = ProductAssets.get_asset!(asset.id)
      assert updated.duration_ms == 42_500
    end
  end

  describe "asynchronous happy path" do
    test "polls until done and persists all video metadata", %{asset: asset} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(@stub_key, fn conn ->
        Agent.update(counter, &(&1 + 1))
        call = Agent.get(counter, & &1)

        cond do
          conn.request_path == "/api/v1/video/normalize" ->
            Req.Test.json(conn, %{"jobId" => "vid-job-1"})

          conn.request_path == "/api/v1/jobs/vid-job-1" and call <= 2 ->
            Req.Test.json(conn, %{"id" => "vid-job-1", "status" => "running"})

          conn.request_path == "/api/v1/jobs/vid-job-1" ->
            Req.Test.json(conn, %{
              "id" => "vid-job-1",
              "status" => "done",
              "result" => %{
                "width" => 1280,
                "height" => 720,
                "duration_ms" => 8_000,
                "normalized_storage_key" => "products/videos/async-normalized.mp4",
                "poster_storage_key" => "products/videos/async-poster.jpg"
              }
            })
        end
      end)

      assert {:ok, _} = perform_job(AssetVideoProcessor, %{"asset_id" => asset.id})

      updated = ProductAssets.get_asset!(asset.id)
      assert updated.status == "processed"
      assert updated.duration_ms == 8_000
      assert updated.normalized_storage_key == "products/videos/async-normalized.mp4"
      assert updated.thumbnail_storage_key == "products/videos/async-poster.jpg"
    end
  end

  describe "Media Forge unavailable" do
    test "marks the asset failed with media_forge_unavailable and writes zero metadata",
         %{asset: asset} do
      config = Application.get_env(:content_forge, @media_forge_key)
      Application.put_env(:content_forge, @media_forge_key, Keyword.put(config, :secret, nil))

      test_pid = self()

      Req.Test.stub(@stub_key, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no HTTP expected when Media Forge is not configured"
      end)

      log =
        capture_log(fn ->
          assert {:cancel, "media_forge_unavailable"} =
                   perform_job(AssetVideoProcessor, %{"asset_id" => asset.id})
        end)

      refute_received :unexpected_http
      assert log =~ "media_forge_unavailable"

      updated = ProductAssets.get_asset!(asset.id)
      assert updated.status == "failed"
      assert updated.error == "media_forge_unavailable"
      assert updated.duration_ms == nil
      assert updated.normalized_storage_key == nil
      assert updated.thumbnail_storage_key == nil
    end
  end

  describe "transient error" do
    test "503 returns {:error, _} for Oban retry; asset stays pending", %{asset: asset} do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, JSON.encode!(%{"error" => "overloaded"}))
      end)

      log =
        capture_log(fn ->
          assert {:error, {:transient, 503, _}} =
                   perform_job(AssetVideoProcessor, %{"asset_id" => asset.id})
        end)

      assert log =~ "transient" or log =~ "503"

      updated = ProductAssets.get_asset!(asset.id)
      assert updated.status == "pending"
      assert updated.error == nil
    end
  end

  describe "permanent failure" do
    test "4xx marks the asset failed with the HTTP status in the reason",
         %{asset: asset} do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(415, JSON.encode!(%{"error" => "unsupported codec"}))
      end)

      log =
        capture_log(fn ->
          assert {:cancel, reason} =
                   perform_job(AssetVideoProcessor, %{"asset_id" => asset.id})

          assert reason =~ "HTTP 415"
        end)

      assert log =~ "415" or log =~ "rejected"

      updated = ProductAssets.get_asset!(asset.id)
      assert updated.status == "failed"
      assert updated.error =~ "415"
    end

    test "async failed status marks the asset failed with the provider reason",
         %{asset: asset} do
      Req.Test.stub(@stub_key, fn conn ->
        cond do
          conn.request_path == "/api/v1/video/normalize" ->
            Req.Test.json(conn, %{"jobId" => "vid-fail-1"})

          conn.request_path == "/api/v1/jobs/vid-fail-1" ->
            Req.Test.json(conn, %{
              "id" => "vid-fail-1",
              "status" => "failed",
              "error" => "encoder crashed"
            })
        end
      end)

      log =
        capture_log(fn ->
          assert {:cancel, reason} =
                   perform_job(AssetVideoProcessor, %{"asset_id" => asset.id})

          assert reason =~ "encoder crashed"
        end)

      assert log =~ "failed"

      updated = ProductAssets.get_asset!(asset.id)
      assert updated.status == "failed"
      assert updated.error =~ "encoder crashed"
    end
  end

  describe "idempotency + guards" do
    test "already-processed asset short-circuits without HTTP", %{asset: asset} do
      {:ok, _} =
        ProductAssets.mark_processed(asset, %{
          width: 100,
          height: 100,
          duration_ms: 1000
        })

      test_pid = self()

      Req.Test.stub(@stub_key, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no HTTP expected for already-processed asset"
      end)

      assert :ok = perform_job(AssetVideoProcessor, %{"asset_id" => asset.id})
      refute_received :unexpected_http
    end

    test "missing asset cancels without issuing HTTP" do
      test_pid = self()

      Req.Test.stub(@stub_key, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no HTTP expected for missing asset"
      end)

      log =
        capture_log(fn ->
          assert {:cancel, "asset not found"} =
                   perform_job(AssetVideoProcessor, %{"asset_id" => Ecto.UUID.generate()})
        end)

      refute_received :unexpected_http
      assert log =~ "not found"
    end
  end
end
