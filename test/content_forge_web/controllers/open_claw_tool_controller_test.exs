defmodule ContentForgeWeb.OpenClawToolControllerTest do
  @moduledoc """
  Phase 16.1 coverage for the OpenClaw tool HTTP surface.

  The controller authenticates via `X-OpenClaw-Tool-Secret`
  (fail-closed on missing / mismatched / unconfigured secret)
  and dispatches to `ContentForge.OpenClawTools.<Tool>.call/2`
  by pattern matching on the URL's tool_name.
  """
  use ContentForgeWeb.ConnCase, async: false

  alias ContentForge.Products

  @secret "openclaw-tool-secret-test-value"

  setup %{conn: conn} do
    original = Application.get_env(:content_forge, :open_claw_tool_secret)
    original_storage = Application.get_env(:content_forge, :asset_storage_impl)

    Application.put_env(:content_forge, :open_claw_tool_secret, @secret)
    Application.put_env(:content_forge, :asset_storage_impl, __MODULE__.StorageStub)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:content_forge, :open_claw_tool_secret)
      else
        Application.put_env(:content_forge, :open_claw_tool_secret, original)
      end

      if is_nil(original_storage) do
        Application.delete_env(:content_forge, :asset_storage_impl)
      else
        Application.put_env(:content_forge, :asset_storage_impl, original_storage)
      end
    end)

    json_conn = put_req_header(conn, "accept", "application/json")
    %{conn: json_conn}
  end

  defmodule StorageStub do
    @moduledoc false
    def presigned_put_url(storage_key, _content_type, _opts) do
      {:ok, "https://stub.example/put/" <> storage_key <> "?sig=abc"}
    end
  end

  describe "auth" do
    test "401 when the secret header is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/openclaw/tools/create_upload_link", %{})
      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    end

    test "401 when the secret header is wrong", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-openclaw-tool-secret", "wrong-secret")
        |> post(~p"/api/v1/openclaw/tools/create_upload_link", %{})

      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    end

    test "401 when the server-side secret is not configured", %{conn: conn} do
      Application.delete_env(:content_forge, :open_claw_tool_secret)

      conn =
        conn
        |> put_req_header("x-openclaw-tool-secret", @secret)
        |> post(~p"/api/v1/openclaw/tools/create_upload_link", %{})

      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    end
  end

  describe "dispatch" do
    test "dispatches to CreateUploadLink and returns a presigned URL",
         %{conn: conn} do
      {:ok, product} =
        Products.create_product(%{name: "Acme Widgets Inc", voice_profile: "professional"})

      body = %{
        "session_id" => "test-session",
        "channel" => "cli",
        "sender_identity" => "cli:ops",
        "params" => %{"product" => "Acme"}
      }

      conn =
        conn
        |> put_req_header("x-openclaw-tool-secret", @secret)
        |> post(~p"/api/v1/openclaw/tools/create_upload_link", body)

      assert %{
               "status" => "ok",
               "result" => %{
                 "url" => url,
                 "storage_key" => storage_key,
                 "product_id" => product_id,
                 "product_name" => "Acme Widgets Inc",
                 "expires_in_seconds" => 900
               }
             } = json_response(conn, 200)

      assert String.starts_with?(url, "https://stub.example/put/")
      assert product_id == product.id
      assert String.starts_with?(storage_key, "products/#{product.id}/assets/")
    end

    test "404 on an unknown tool name", %{conn: conn} do
      body = %{"params" => %{}}

      conn =
        conn
        |> put_req_header("x-openclaw-tool-secret", @secret)
        |> post(~p"/api/v1/openclaw/tools/wat_is_this", body)

      assert %{"status" => "error", "error" => "unknown_tool", "tool_name" => "wat_is_this"} =
               json_response(conn, 404)
    end

    test "422 on classified tool error (product not found)", %{conn: conn} do
      body = %{"params" => %{"product" => "does-not-exist"}}

      conn =
        conn
        |> put_req_header("x-openclaw-tool-secret", @secret)
        |> post(~p"/api/v1/openclaw/tools/create_upload_link", body)

      assert %{"status" => "error", "error" => "product_not_found"} =
               json_response(conn, 422)
    end

    test "422 on ambiguous product match", %{conn: conn} do
      {:ok, _} =
        Products.create_product(%{name: "Ambiguous One", voice_profile: "professional"})

      {:ok, _} =
        Products.create_product(%{name: "Ambiguous Two", voice_profile: "professional"})

      body = %{"params" => %{"product" => "Ambiguous"}}

      conn =
        conn
        |> put_req_header("x-openclaw-tool-secret", @secret)
        |> post(~p"/api/v1/openclaw/tools/create_upload_link", body)

      assert %{"status" => "error", "error" => "ambiguous_product"} =
               json_response(conn, 422)
    end
  end
end
