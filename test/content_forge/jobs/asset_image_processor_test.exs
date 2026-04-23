defmodule ContentForge.Jobs.AssetImageProcessorTest do
  use ContentForge.DataCase, async: false
  use Oban.Testing, repo: ContentForge.Repo

  import ExUnit.CaptureLog

  alias ContentForge.Jobs.AssetImageProcessor
  alias ContentForge.ProductAssets
  alias ContentForge.Products

  @media_forge_key :media_forge
  @processor_key :asset_image_processor
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
        storage_key: "products/#{product.id}/assets/abc/hero.jpg",
        media_type: "image",
        filename: "hero.jpg",
        mime_type: "image/jpeg",
        byte_size: 102_400,
        uploaded_at: DateTime.utc_now()
      })

    %{product: product, asset: asset}
  end

  describe "synchronous happy path" do
    test "persists width, height, and thumbnail_storage_key from the sync response",
         %{asset: asset} do
      Req.Test.stub(@stub_key, fn conn ->
        assert conn.request_path == "/api/v1/image/process"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        {:ok, decoded} = JSON.decode(body)

        assert decoded["source_key"] == asset.storage_key
        assert "autorotate" in decoded["transforms"]
        assert "strip_exif" in decoded["transforms"]
        assert "thumbnail" in decoded["transforms"]
        assert "probe" in decoded["transforms"]

        Req.Test.json(conn, %{
          "result" => %{
            "width" => 1920,
            "height" => 1080,
            "thumbnail_storage_key" => "products/thumbs/hero_thumb.jpg"
          }
        })
      end)

      assert {:ok, _} = perform_job(AssetImageProcessor, %{"asset_id" => asset.id})

      updated = ProductAssets.get_asset!(asset.id)
      assert updated.status == "processed"
      assert updated.width == 1920
      assert updated.height == 1080
      assert updated.thumbnail_storage_key == "products/thumbs/hero_thumb.jpg"
      assert updated.error == nil
    end
  end

  describe "asynchronous happy path" do
    test "polls get_job until done and persists the result", %{asset: asset} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(@stub_key, fn conn ->
        Agent.update(counter, &(&1 + 1))
        call = Agent.get(counter, & &1)

        cond do
          conn.request_path == "/api/v1/image/process" ->
            Req.Test.json(conn, %{"jobId" => "img-job-1"})

          conn.request_path == "/api/v1/jobs/img-job-1" and call <= 2 ->
            Req.Test.json(conn, %{"id" => "img-job-1", "status" => "pending"})

          conn.request_path == "/api/v1/jobs/img-job-1" ->
            Req.Test.json(conn, %{
              "id" => "img-job-1",
              "status" => "done",
              "result" => %{
                "width" => 800,
                "height" => 600,
                "thumbnail_storage_key" => "products/thumbs/async.jpg"
              }
            })
        end
      end)

      assert {:ok, _} = perform_job(AssetImageProcessor, %{"asset_id" => asset.id})

      updated = ProductAssets.get_asset!(asset.id)
      assert updated.status == "processed"
      assert updated.width == 800
      assert updated.height == 600
      assert updated.thumbnail_storage_key == "products/thumbs/async.jpg"
    end
  end

  describe "Media Forge unavailable" do
    test "marks the asset failed with media_forge_unavailable and writes no dimensions",
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
                   perform_job(AssetImageProcessor, %{"asset_id" => asset.id})
        end)

      refute_received :unexpected_http
      assert log =~ "media_forge_unavailable"

      updated = ProductAssets.get_asset!(asset.id)
      assert updated.status == "failed"
      assert updated.error == "media_forge_unavailable"
      assert updated.width == nil
      assert updated.height == nil
      assert updated.thumbnail_storage_key == nil
    end
  end

  describe "transient error" do
    test "503 returns {:error, _} so Oban retries; asset stays pending", %{asset: asset} do
      Req.Test.stub(@stub_key, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, JSON.encode!(%{"error" => "overloaded"}))
      end)

      log =
        capture_log(fn ->
          assert {:error, {:transient, 503, _}} =
                   perform_job(AssetImageProcessor, %{"asset_id" => asset.id})
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
        |> Plug.Conn.resp(422, JSON.encode!(%{"error" => "invalid source"}))
      end)

      log =
        capture_log(fn ->
          assert {:cancel, reason} =
                   perform_job(AssetImageProcessor, %{"asset_id" => asset.id})

          assert reason =~ "HTTP 422"
        end)

      assert log =~ "422" or log =~ "rejected"

      updated = ProductAssets.get_asset!(asset.id)
      assert updated.status == "failed"
      assert updated.error =~ "422"
    end

    test "async failed status marks the asset failed with the error reason",
         %{asset: asset} do
      Req.Test.stub(@stub_key, fn conn ->
        cond do
          conn.request_path == "/api/v1/image/process" ->
            Req.Test.json(conn, %{"jobId" => "img-fail-1"})

          conn.request_path == "/api/v1/jobs/img-fail-1" ->
            Req.Test.json(conn, %{
              "id" => "img-fail-1",
              "status" => "failed",
              "error" => "provider said no"
            })
        end
      end)

      log =
        capture_log(fn ->
          assert {:cancel, reason} =
                   perform_job(AssetImageProcessor, %{"asset_id" => asset.id})

          assert reason =~ "provider said no"
        end)

      assert log =~ "failed"

      updated = ProductAssets.get_asset!(asset.id)
      assert updated.status == "failed"
      assert updated.error =~ "provider said no"
    end
  end

  describe "idempotency + guards" do
    test "already-processed asset short-circuits without HTTP", %{asset: asset} do
      {:ok, _} = ProductAssets.mark_processed(asset, %{width: 100, height: 100})

      test_pid = self()

      Req.Test.stub(@stub_key, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no HTTP expected for already-processed asset"
      end)

      assert :ok = perform_job(AssetImageProcessor, %{"asset_id" => asset.id})
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
                   perform_job(AssetImageProcessor, %{"asset_id" => Ecto.UUID.generate()})
        end)

      refute_received :unexpected_http
      assert log =~ "not found"
    end
  end
end
