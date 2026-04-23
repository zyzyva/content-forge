defmodule ContentForgeWeb.ProductAssetControllerTest do
  use ContentForgeWeb.ConnCase
  use Oban.Testing, repo: ContentForge.Repo

  alias ContentForge.Accounts
  alias ContentForge.Jobs.AssetImageProcessor
  alias ContentForge.Jobs.AssetVideoProcessor
  alias ContentForge.ProductAssets
  alias ContentForge.Products

  defmodule PresignStub do
    @moduledoc false
    def presigned_put_url(key, content_type, _opts) do
      {:ok, "https://stub.example/put/#{key}?content-type=#{content_type}"}
    end
  end

  defmodule PresignFailureStub do
    @moduledoc false
    def presigned_put_url(_key, _content_type, _opts), do: {:error, :boom}
  end

  setup %{conn: conn} do
    original_impl = Application.get_env(:content_forge, :asset_storage_impl)
    Application.put_env(:content_forge, :asset_storage_impl, PresignStub)

    on_exit(fn ->
      if original_impl do
        Application.put_env(:content_forge, :asset_storage_impl, original_impl)
      else
        Application.delete_env(:content_forge, :asset_storage_impl)
      end
    end)

    {:ok, api_key} =
      Accounts.create_api_key(%{
        key: String.duplicate("d", 32),
        label: "assets test key",
        active: true
      })

    {:ok, product} =
      Products.create_product(%{name: "Test Product", voice_profile: "professional"})

    authed =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{api_key.key}")

    %{conn: authed, product: product, api_key: api_key}
  end

  describe "POST /api/v1/products/:product_id/assets/presigned-upload" do
    test "returns a presigned PUT URL, storage key, and expiry for a valid image",
         %{conn: conn, product: product} do
      params = %{
        "filename" => "hero.jpg",
        "content_type" => "image/jpeg",
        "byte_size" => 250_000
      }

      conn = post(conn, ~p"/api/v1/products/#{product.id}/assets/presigned-upload", params)

      assert %{"data" => data} = json_response(conn, 200)
      assert data["url"] =~ "products/#{product.id}/assets/"
      assert data["url"] =~ "content-type=image/jpeg"
      assert data["storage_key"] =~ "products/#{product.id}/assets/"
      assert data["storage_key"] =~ "hero.jpg"
      assert data["expires_in_seconds"] == 900
      assert data["content_type"] == "image/jpeg"
      assert data["byte_size"] == 250_000
    end

    test "accepts a video content type and video byte-size caps", %{conn: conn, product: product} do
      params = %{
        "filename" => "demo.mp4",
        "content_type" => "video/mp4",
        "byte_size" => 100 * 1_024 * 1_024
      }

      conn = post(conn, ~p"/api/v1/products/#{product.id}/assets/presigned-upload", params)
      assert %{"data" => data} = json_response(conn, 200)
      assert data["storage_key"] =~ "demo.mp4"
    end

    test "rejects unsupported content type with 415", %{conn: conn, product: product} do
      params = %{
        "filename" => "doc.pdf",
        "content_type" => "application/pdf",
        "byte_size" => 1_000
      }

      conn = post(conn, ~p"/api/v1/products/#{product.id}/assets/presigned-upload", params)
      body = json_response(conn, 415)
      assert body["error"] =~ "unsupported"
      assert "image/jpeg" in body["allowed"]
    end

    test "rejects oversized image (> 50MB) with 413", %{conn: conn, product: product} do
      params = %{
        "filename" => "huge.jpg",
        "content_type" => "image/jpeg",
        "byte_size" => 60 * 1_024 * 1_024
      }

      conn = post(conn, ~p"/api/v1/products/#{product.id}/assets/presigned-upload", params)
      body = json_response(conn, 413)
      assert body["error"] =~ "too large"
      assert body["max_bytes"] == 50 * 1_024 * 1_024
      assert body["got_bytes"] == 60 * 1_024 * 1_024
    end

    test "rejects oversized video (> 500MB) with 413", %{conn: conn, product: product} do
      params = %{
        "filename" => "huge.mp4",
        "content_type" => "video/mp4",
        "byte_size" => 600 * 1_024 * 1_024
      }

      conn = post(conn, ~p"/api/v1/products/#{product.id}/assets/presigned-upload", params)
      body = json_response(conn, 413)
      assert body["max_bytes"] == 500 * 1_024 * 1_024
    end

    test "rejects missing required fields with 422", %{conn: conn, product: product} do
      conn = post(conn, ~p"/api/v1/products/#{product.id}/assets/presigned-upload", %{})
      body = json_response(conn, 422)
      assert body["error"] =~ "missing required field"
    end

    test "returns 404 for an unknown product", %{conn: conn} do
      params = %{
        "filename" => "hero.jpg",
        "content_type" => "image/jpeg",
        "byte_size" => 1_000
      }

      conn =
        post(conn, ~p"/api/v1/products/#{Ecto.UUID.generate()}/assets/presigned-upload", params)

      body = json_response(conn, 404)
      assert body["error"] =~ "product not found"
    end

    test "surfaces a 502 when the storage impl fails to presign",
         %{conn: conn, product: product} do
      Application.put_env(:content_forge, :asset_storage_impl, PresignFailureStub)

      params = %{
        "filename" => "hero.jpg",
        "content_type" => "image/jpeg",
        "byte_size" => 1_000
      }

      conn = post(conn, ~p"/api/v1/products/#{product.id}/assets/presigned-upload", params)
      body = json_response(conn, 502)
      assert body["error"] =~ "presign failed"
    end

    test "rejects requests without a bearer token", %{product: product} do
      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("accept", "application/json")

      params = %{
        "filename" => "hero.jpg",
        "content_type" => "image/jpeg",
        "byte_size" => 1_000
      }

      conn = post(conn, ~p"/api/v1/products/#{product.id}/assets/presigned-upload", params)
      assert json_response(conn, 401)
    end

    test "sanitises weird characters in the filename", %{conn: conn, product: product} do
      params = %{
        "filename" => "../../etc/passwd  shady file!.jpg",
        "content_type" => "image/jpeg",
        "byte_size" => 1_000
      }

      conn = post(conn, ~p"/api/v1/products/#{product.id}/assets/presigned-upload", params)
      %{"data" => data} = json_response(conn, 200)
      refute data["storage_key"] =~ ".."
      refute data["storage_key"] =~ "/etc/"

      assert data["storage_key"] =~ "passwd__shady_file_.jpg" or
               data["storage_key"] =~ "passwd"
    end
  end

  describe "POST /api/v1/products/:product_id/assets/register" do
    test "creates a ProductAsset in pending and enqueues the image processor",
         %{conn: conn, product: product} do
      storage_key = "products/#{product.id}/assets/abc/hero.jpg"

      params = %{
        "storage_key" => storage_key,
        "filename" => "hero.jpg",
        "content_type" => "image/jpeg",
        "byte_size" => 200_000,
        "uploader" => "test-suite",
        "tags" => ["hero", "launch"]
      }

      conn = post(conn, ~p"/api/v1/products/#{product.id}/assets/register", params)

      assert %{"data" => data} = json_response(conn, 201)
      assert data["status"] == "pending"
      assert data["media_type"] == "image"
      assert data["storage_key"] == storage_key
      assert data["tags"] == ["hero", "launch"]

      asset = ProductAssets.get_asset!(data["id"])
      assert asset.uploader == "test-suite"

      assert_enqueued(worker: AssetImageProcessor, args: %{"asset_id" => data["id"]})
      refute_enqueued(worker: AssetVideoProcessor)
    end

    test "video registration enqueues the video processor, not the image processor",
         %{conn: conn, product: product} do
      storage_key = "products/#{product.id}/assets/xyz/demo.mp4"

      params = %{
        "storage_key" => storage_key,
        "filename" => "demo.mp4",
        "content_type" => "video/mp4",
        "byte_size" => 5_000_000
      }

      conn = post(conn, ~p"/api/v1/products/#{product.id}/assets/register", params)
      %{"data" => data} = json_response(conn, 201)
      assert data["media_type"] == "video"

      assert_enqueued(worker: AssetVideoProcessor, args: %{"asset_id" => data["id"]})
      refute_enqueued(worker: AssetImageProcessor)
    end

    test "rejects unsupported content type with 415 and creates no row",
         %{conn: conn, product: product} do
      params = %{
        "storage_key" => "products/#{product.id}/assets/abc/doc.pdf",
        "filename" => "doc.pdf",
        "content_type" => "application/pdf",
        "byte_size" => 1_000
      }

      conn = post(conn, ~p"/api/v1/products/#{product.id}/assets/register", params)
      assert json_response(conn, 415)
      assert ProductAssets.list_assets(product.id) == []
      refute_enqueued(worker: AssetImageProcessor)
      refute_enqueued(worker: AssetVideoProcessor)
    end

    test "rejects oversized image with 413 and creates no row",
         %{conn: conn, product: product} do
      params = %{
        "storage_key" => "products/#{product.id}/assets/abc/huge.jpg",
        "filename" => "huge.jpg",
        "content_type" => "image/jpeg",
        "byte_size" => 60 * 1_024 * 1_024
      }

      conn = post(conn, ~p"/api/v1/products/#{product.id}/assets/register", params)
      assert json_response(conn, 413)
      assert ProductAssets.list_assets(product.id) == []
      refute_enqueued(worker: AssetImageProcessor)
    end

    test "rejects missing required fields with 422", %{conn: conn, product: product} do
      conn = post(conn, ~p"/api/v1/products/#{product.id}/assets/register", %{})
      assert json_response(conn, 422)
      refute_enqueued(worker: AssetImageProcessor)
    end

    test "returns 422 when the same storage_key is re-registered for the same product",
         %{conn: conn, product: product} do
      storage_key = "products/#{product.id}/assets/abc/dup.jpg"

      params = %{
        "storage_key" => storage_key,
        "filename" => "dup.jpg",
        "content_type" => "image/jpeg",
        "byte_size" => 1_000
      }

      assert %{} =
               json_response(
                 post(conn, ~p"/api/v1/products/#{product.id}/assets/register", params),
                 201
               )

      second = post(conn, ~p"/api/v1/products/#{product.id}/assets/register", params)
      body = json_response(second, 422)
      assert body["errors"] != %{}
    end

    test "returns 401 without a bearer token", %{product: product} do
      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("accept", "application/json")

      params = %{
        "storage_key" => "products/#{product.id}/assets/abc/hero.jpg",
        "filename" => "hero.jpg",
        "content_type" => "image/jpeg",
        "byte_size" => 1_000
      }

      conn = post(conn, ~p"/api/v1/products/#{product.id}/assets/register", params)
      assert json_response(conn, 401)
    end
  end
end
