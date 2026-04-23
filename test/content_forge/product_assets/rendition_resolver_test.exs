defmodule ContentForge.ProductAssets.RenditionResolverTest do
  use ContentForge.DataCase, async: false

  alias ContentForge.ProductAssets
  alias ContentForge.ProductAssets.AssetRendition
  alias ContentForge.ProductAssets.RenditionResolver
  alias ContentForge.Products

  @mf_key :media_forge
  @mf_stub ContentForge.MediaForge
  @rend_key :renditions

  @twitter_spec %{aspect: "16:9", width: 1200, format: "jpg"}
  @instagram_spec %{aspect: "1:1", width: 1080, format: "jpg"}

  setup context do
    mf_original = Application.get_env(:content_forge, @mf_key, [])
    rend_original = Application.get_env(:content_forge, @rend_key, nil)

    on_exit(fn ->
      Application.put_env(:content_forge, @mf_key, mf_original)
      restore_rend_config(rend_original)
    end)

    Application.put_env(:content_forge, @mf_key,
      base_url: "http://media-forge.test",
      secret: "test-secret",
      req_options: [plug: {Req.Test, @mf_stub}]
    )

    Application.put_env(:content_forge, @rend_key, %{
      "twitter" => @twitter_spec,
      "instagram" => @instagram_spec
    })

    {:ok, product} =
      Products.create_product(%{name: "Rendition Product", voice_profile: "professional"})

    {:ok, image_asset} =
      ProductAssets.create_asset(%{
        product_id: product.id,
        storage_key: "products/#{product.id}/assets/hero.jpg",
        filename: "hero.jpg",
        mime_type: "image/jpeg",
        media_type: "image",
        byte_size: 10_240,
        uploaded_at: DateTime.utc_now()
      })

    {:ok, video_asset} =
      ProductAssets.create_asset(%{
        product_id: product.id,
        storage_key: "products/#{product.id}/assets/clip.mp4",
        filename: "clip.mp4",
        mime_type: "video/mp4",
        media_type: "video",
        byte_size: 50_000,
        uploaded_at: DateTime.utc_now()
      })

    context
    |> Map.put(:image_asset, image_asset)
    |> Map.put(:video_asset, video_asset)
  end

  defp restore_rend_config(nil), do: Application.delete_env(:content_forge, @rend_key)
  defp restore_rend_config(val), do: Application.put_env(:content_forge, @rend_key, val)

  describe "unknown platform" do
    test "returns the asset's primary public URL without calling Media Forge",
         %{image_asset: asset} do
      test_pid = self()

      Req.Test.stub(@mf_stub, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no Media Forge HTTP expected for unknown platform"
      end)

      assert {:ok, url} = RenditionResolver.resolve(asset, "mastodon")
      refute_received :unexpected_http

      assert url == ContentForge.Storage.get_publicUrl(asset.storage_key)
    end
  end

  describe "cache hit" do
    test "returns the cached rendition URL without calling Media Forge",
         %{image_asset: asset} do
      rendition_key = "renditions/#{asset.id}/twitter-cached.jpg"

      {:ok, _rendition} =
        %AssetRendition{}
        |> AssetRendition.changeset(%{
          asset_id: asset.id,
          platform: "twitter",
          storage_key: rendition_key,
          status: "ready",
          width: 1200,
          format: "jpg"
        })
        |> Repo.insert()

      test_pid = self()

      Req.Test.stub(@mf_stub, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no Media Forge HTTP expected on cache hit"
      end)

      assert {:ok, url} = RenditionResolver.resolve(asset, "twitter")
      refute_received :unexpected_http
      assert url == ContentForge.Storage.get_publicUrl(rendition_key)
    end

    test "a cached 'failed' row does not short-circuit; retry calls Media Forge",
         %{image_asset: asset} do
      rendition_key = "renditions/#{asset.id}/twitter-failed.jpg"
      output_key = "renditions/#{asset.id}/twitter-retried.jpg"

      {:ok, _rendition} =
        %AssetRendition{}
        |> AssetRendition.changeset(%{
          asset_id: asset.id,
          platform: "twitter",
          storage_key: rendition_key,
          status: "failed"
        })
        |> Repo.insert()

      Req.Test.stub(@mf_stub, fn conn ->
        assert conn.request_path == "/api/v1/image/render"
        Req.Test.json(conn, %{"status" => "done", "storage_key" => output_key})
      end)

      assert {:ok, url} = RenditionResolver.resolve(asset, "twitter")
      assert url == ContentForge.Storage.get_publicUrl(output_key)

      reloaded = Repo.get_by!(AssetRendition, asset_id: asset.id, platform: "twitter")
      assert reloaded.storage_key == output_key
      assert reloaded.status == "ready"
    end
  end

  describe "cache miss - image" do
    test "calls MediaForge.enqueue_image_render with source + spec and persists the rendition",
         %{image_asset: asset} do
      test_pid = self()
      output_key = "renditions/#{asset.id}/twitter.jpg"

      Req.Test.stub(@mf_stub, fn conn ->
        assert conn.request_path == "/api/v1/image/render"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        {:ok, decoded} = JSON.decode(body)
        send(test_pid, {:mf_body, decoded})

        Req.Test.json(conn, %{
          "status" => "done",
          "storage_key" => output_key,
          "width" => 1200,
          "height" => 675,
          "format" => "jpg"
        })
      end)

      assert {:ok, url} = RenditionResolver.resolve(asset, "twitter")
      assert url == ContentForge.Storage.get_publicUrl(output_key)

      assert_received {:mf_body, body}

      assert body["storage_key"] == asset.storage_key ||
               body["source_storage_key"] == asset.storage_key

      assert body["spec"]["aspect"] == "16:9"
      assert body["spec"]["width"] == 1200
      assert body["spec"]["format"] == "jpg"
      assert body["platform"] == "twitter"

      [rendition] = Repo.all(AssetRendition)
      assert rendition.asset_id == asset.id
      assert rendition.platform == "twitter"
      assert rendition.storage_key == output_key
      assert rendition.status == "ready"
      assert rendition.width == 1200
      assert rendition.height == 675
      assert rendition.format == "jpg"
    end

    test "supports Media Forge sync responses that nest the key under 'result'",
         %{image_asset: asset} do
      output_key = "renditions/#{asset.id}/instagram.jpg"

      Req.Test.stub(@mf_stub, fn conn ->
        Req.Test.json(conn, %{
          "status" => "done",
          "result" => %{"storage_key" => output_key, "width" => 1080, "height" => 1080}
        })
      end)

      assert {:ok, url} = RenditionResolver.resolve(asset, "instagram")
      assert url == ContentForge.Storage.get_publicUrl(output_key)
      assert Repo.get_by!(AssetRendition, asset_id: asset.id, platform: "instagram")
    end
  end

  describe "cache miss - error pass-through" do
    test "surfaces :not_configured cleanly when Media Forge has no secret",
         %{image_asset: asset} do
      cfg = Application.get_env(:content_forge, @mf_key) |> Keyword.put(:secret, nil)
      Application.put_env(:content_forge, @mf_key, cfg)

      test_pid = self()

      Req.Test.stub(@mf_stub, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no HTTP expected when Media Forge is not configured"
      end)

      assert {:error, :not_configured} = RenditionResolver.resolve(asset, "twitter")
      refute_received :unexpected_http
      assert [] = Repo.all(AssetRendition)
    end

    test "propagates transient 503 as {:transient, 503, _}",
         %{image_asset: asset} do
      Req.Test.stub(@mf_stub, fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{"error" => "unavailable"})
      end)

      assert {:error, {:transient, 503, _}} = RenditionResolver.resolve(asset, "twitter")
      assert [] = Repo.all(AssetRendition)
    end

    test "propagates permanent 400 as {:http_error, 400, _}",
         %{image_asset: asset} do
      Req.Test.stub(@mf_stub, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => "bad spec"})
      end)

      assert {:error, {:http_error, 400, _}} = RenditionResolver.resolve(asset, "twitter")
      assert [] = Repo.all(AssetRendition)
    end

    test "unrecognized sync response cancels cleanly without persisting",
         %{image_asset: asset} do
      Req.Test.stub(@mf_stub, fn conn ->
        Req.Test.json(conn, %{"status" => "done"})
      end)

      assert {:error, {:unexpected_body, _}} =
               RenditionResolver.resolve(asset, "twitter")

      assert [] = Repo.all(AssetRendition)
    end
  end

  describe "video path (wired but not yet exercised)" do
    test "dispatches video renditions to MediaForge.enqueue_video_batch",
         %{video_asset: asset} do
      test_pid = self()

      Req.Test.stub(@mf_stub, fn conn ->
        send(test_pid, {:path, conn.request_path})
        Req.Test.json(conn, %{"jobId" => "video-job-1", "status" => "pending"})
      end)

      assert {:ok, {:async, "video-job-1"}} = RenditionResolver.resolve(asset, "twitter")
      assert_received {:path, "/api/v1/video/batch"}
    end
  end
end
