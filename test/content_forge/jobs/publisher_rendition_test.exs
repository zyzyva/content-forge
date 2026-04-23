defmodule ContentForge.Jobs.PublisherRenditionTest do
  use ContentForge.DataCase, async: false
  use Oban.Testing, repo: ContentForge.Repo

  import ExUnit.CaptureLog

  alias ContentForge.ContentGeneration
  alias ContentForge.Jobs.Publisher
  alias ContentForge.ProductAssets
  alias ContentForge.ProductAssets.AssetRendition
  alias ContentForge.Products

  @mf_key :media_forge
  @mf_stub ContentForge.MediaForge
  @rend_key :renditions

  setup do
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
      "twitter" => %{aspect: "16:9", width: 1200, format: "jpg"},
      "instagram" => %{aspect: "1:1", width: 1080, format: "jpg"},
      "facebook" => %{aspect: "1:1", width: 1080, format: "jpg"}
    })

    {:ok, product} =
      Products.create_product(%{
        name: "Rendition Publisher Product",
        voice_profile: "professional"
      })

    %{product: product}
  end

  defp restore_rend_config(nil), do: Application.delete_env(:content_forge, @rend_key)
  defp restore_rend_config(val), do: Application.put_env(:content_forge, @rend_key, val)

  defp create_asset!(product, overrides) do
    defaults = %{
      product_id: product.id,
      storage_key: "products/#{product.id}/assets/#{Ecto.UUID.generate()}/file.jpg",
      filename: "file.jpg",
      mime_type: "image/jpeg",
      media_type: "image",
      byte_size: 1024,
      uploaded_at: DateTime.utc_now()
    }

    {:ok, asset} = ProductAssets.create_asset(Map.merge(defaults, overrides))
    asset
  end

  defp create_approved_draft!(product, attrs) do
    defaults = %{
      product_id: product.id,
      content: "Social post copy",
      platform: "twitter",
      content_type: "post",
      generating_model: "claude",
      status: "approved",
      image_url: "legacy://placeholder"
    }

    {:ok, draft} = ContentGeneration.create_draft(Map.merge(defaults, attrs))
    draft
  end

  defp seed_ready_rendition!(asset, platform, output_key) do
    {:ok, rendition} =
      %AssetRendition{}
      |> AssetRendition.changeset(%{
        asset_id: asset.id,
        platform: platform,
        storage_key: output_key,
        status: "ready",
        width: 1200,
        format: "jpg"
      })
      |> Repo.insert()

    rendition
  end

  describe "build_post_opts/4 - resolution path" do
    test "primary image_url comes from the resolution, not draft.image_url", %{product: product} do
      draft =
        create_approved_draft!(product, %{
          platform: "twitter",
          image_url: "legacy://fallback"
        })

      resolution = %{primary_url: "https://cdn/resolved.jpg", gallery_urls: []}

      opts = Publisher.build_post_opts(draft, [], product, resolution)

      assert opts[:image_url] == "https://cdn/resolved.jpg"
      refute opts[:image_url] == "legacy://fallback"
    end

    test "includes :carousel on instagram when gallery_urls is non-empty",
         %{product: product} do
      draft = create_approved_draft!(product, %{platform: "instagram"})

      resolution = %{
        primary_url: "https://cdn/a.jpg",
        gallery_urls: ["https://cdn/b.jpg", "https://cdn/c.jpg"]
      }

      opts = Publisher.build_post_opts(draft, [], product, resolution)

      assert opts[:image_url] == "https://cdn/a.jpg"
      assert opts[:carousel] == ["https://cdn/b.jpg", "https://cdn/c.jpg"]
    end

    test "includes :carousel on facebook when gallery_urls is non-empty", %{product: product} do
      draft = create_approved_draft!(product, %{platform: "facebook"})

      resolution = %{
        primary_url: "https://cdn/a.jpg",
        gallery_urls: ["https://cdn/b.jpg"]
      }

      opts = Publisher.build_post_opts(draft, [], product, resolution)

      assert opts[:carousel] == ["https://cdn/b.jpg"]
    end

    test "omits :carousel on twitter even when gallery_urls has entries", %{product: product} do
      draft = create_approved_draft!(product, %{platform: "twitter"})

      resolution = %{
        primary_url: "https://cdn/a.jpg",
        gallery_urls: ["https://cdn/b.jpg"]
      }

      opts = Publisher.build_post_opts(draft, [], product, resolution)

      refute Keyword.has_key?(opts, :carousel)
      assert opts[:image_url] == "https://cdn/a.jpg"
    end

    test "omits :carousel on carousel-capable platform when gallery_urls is empty",
         %{product: product} do
      draft = create_approved_draft!(product, %{platform: "instagram"})
      resolution = %{primary_url: "https://cdn/a.jpg", gallery_urls: []}

      opts = Publisher.build_post_opts(draft, [], product, resolution)

      refute Keyword.has_key?(opts, :carousel)
    end
  end

  describe "legacy draft (no attachments) keeps draft.image_url" do
    test "no resolver HTTP; image_url comes from the draft itself", %{product: product} do
      draft =
        create_approved_draft!(product, %{
          platform: "twitter",
          image_url: "https://cdn/legacy.jpg"
        })

      test_pid = self()

      Req.Test.stub(@mf_stub, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no Media Forge HTTP expected for legacy draft"
      end)

      capture_log(fn ->
        assert {:cancel, "No credentials for platform"} =
                 perform_job(Publisher, %{"draft_id" => draft.id})
      end)

      refute_received :unexpected_http

      updated = ContentGeneration.get_draft!(draft.id)
      assert updated.status == "approved"
      assert updated.image_url == "https://cdn/legacy.jpg"
    end
  end

  describe "draft with attached featured asset" do
    test "resolver is called; Publisher reaches credentials check using the resolved URL",
         %{product: product} do
      asset = create_asset!(product, %{filename: "hero.jpg"})

      draft =
        create_approved_draft!(product, %{
          platform: "twitter",
          image_url: asset.storage_key
        })

      {:ok, _} = ContentGeneration.attach_asset(draft, asset, role: "featured")

      test_pid = self()
      output_key = "renditions/#{asset.id}/twitter-live.jpg"

      Req.Test.stub(@mf_stub, fn conn ->
        assert conn.request_path == "/api/v1/image/render"
        send(test_pid, :mf_hit)
        Req.Test.json(conn, %{"status" => "done", "storage_key" => output_key})
      end)

      capture_log(fn ->
        assert {:cancel, "No credentials for platform"} =
                 perform_job(Publisher, %{"draft_id" => draft.id})
      end)

      assert_received :mf_hit

      # After publish reaches the credentials gate, the rendition should have
      # been cached so a second attempt skips Media Forge.
      assert [rendition] = Repo.all(AssetRendition)
      assert rendition.storage_key == output_key
      assert rendition.platform == "twitter"
    end

    test "cached rendition skips Media Forge entirely", %{product: product} do
      asset = create_asset!(product, %{filename: "cached.jpg"})

      draft =
        create_approved_draft!(product, %{
          platform: "twitter",
          image_url: asset.storage_key
        })

      {:ok, _} = ContentGeneration.attach_asset(draft, asset, role: "featured")

      seed_ready_rendition!(asset, "twitter", "renditions/#{asset.id}/twitter-cached.jpg")

      test_pid = self()

      Req.Test.stub(@mf_stub, fn _conn ->
        send(test_pid, :unexpected_http)
        raise "no Media Forge HTTP expected with cached rendition"
      end)

      capture_log(fn ->
        assert {:cancel, "No credentials for platform"} =
                 perform_job(Publisher, %{"draft_id" => draft.id})
      end)

      refute_received :unexpected_http
    end
  end

  describe "resolver error taxonomy at publish time" do
    test ":not_configured blocks the draft and logs rendition-unavailable",
         %{product: product} do
      cfg = Application.get_env(:content_forge, @mf_key) |> Keyword.put(:secret, nil)
      Application.put_env(:content_forge, @mf_key, cfg)

      asset = create_asset!(product, %{filename: "b.jpg"})

      draft =
        create_approved_draft!(product, %{
          platform: "twitter",
          image_url: asset.storage_key
        })

      {:ok, _} = ContentGeneration.attach_asset(draft, asset, role: "featured")

      log =
        capture_log(fn ->
          assert {:cancel, reason} = perform_job(Publisher, %{"draft_id" => draft.id})
          assert reason =~ "rendition unavailable"
        end)

      assert log =~ "rendition unavailable"
      assert log =~ "media forge not configured"

      assert ContentGeneration.get_draft!(draft.id).status == "blocked"
    end

    test "permanent 400 error from Media Forge blocks the draft", %{product: product} do
      asset = create_asset!(product, %{filename: "p.jpg"})

      draft =
        create_approved_draft!(product, %{
          platform: "twitter",
          image_url: asset.storage_key
        })

      {:ok, _} = ContentGeneration.attach_asset(draft, asset, role: "featured")

      Req.Test.stub(@mf_stub, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => "bad spec"})
      end)

      log =
        capture_log(fn ->
          assert {:cancel, reason} = perform_job(Publisher, %{"draft_id" => draft.id})
          assert reason =~ "rendition"
          assert reason =~ "400"
        end)

      assert log =~ "rendition"
      assert ContentGeneration.get_draft!(draft.id).status == "blocked"
    end

    test "transient 503 returns {:error, _} for Oban retry; draft stays approved",
         %{product: product} do
      asset = create_asset!(product, %{filename: "t.jpg"})

      draft =
        create_approved_draft!(product, %{
          platform: "twitter",
          image_url: asset.storage_key
        })

      {:ok, _} = ContentGeneration.attach_asset(draft, asset, role: "featured")

      Req.Test.stub(@mf_stub, fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{"error" => "overloaded"})
      end)

      log =
        capture_log(fn ->
          assert {:error, {:transient, 503, _}} =
                   perform_job(Publisher, %{"draft_id" => draft.id})
        end)

      assert log =~ "transient"
      assert ContentGeneration.get_draft!(draft.id).status == "approved"
    end
  end
end
