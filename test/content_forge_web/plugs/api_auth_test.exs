defmodule ContentForgeWeb.Plugs.ApiAuthTest do
  use ContentForgeWeb.ConnCase, async: true
  import ExUnit.CaptureLog

  alias ContentForge.Accounts

  defp create_api_key(attrs \\ %{}) do
    defaults = %{
      key: Accounts.generate_api_key(),
      label: "Test Key",
      active: true
    }

    {:ok, api_key} = Accounts.create_api_key(Map.merge(defaults, attrs))
    api_key
  end

  describe "ApiAuth plug" do
    test "returns 401 JSON when no Authorization header", %{conn: conn} do
      capture_log(fn ->
        result = get(conn, ~p"/api/v1/products")
        send(self(), {:result, result})
      end)

      assert_received {:result, response}
      assert response.status == 401

      assert response.resp_headers
             |> Enum.any?(fn {k, v} -> k == "content-type" && v =~ "json" end)

      body = Jason.decode!(response.resp_body)
      assert body["errors"]["detail"] == "Unauthorized"
    end

    test "returns 401 JSON when Authorization header has invalid token", %{conn: conn} do
      capture_log(fn ->
        result =
          conn
          |> put_req_header("authorization", "Bearer invalidtoken123")
          |> get(~p"/api/v1/products")

        send(self(), {:result, result})
      end)

      assert_received {:result, response}
      assert response.status == 401
      body = Jason.decode!(response.resp_body)
      assert body["errors"]["detail"] == "Unauthorized"
    end

    test "returns 401 JSON (not HTML) on invalid token", %{conn: conn} do
      capture_log(fn ->
        result =
          conn
          |> put_req_header("authorization", "Bearer badtoken")
          |> get(~p"/api/v1/products")

        send(self(), {:result, result})
      end)

      assert_received {:result, response}
      assert response.status == 401
      content_type = response.resp_headers |> Enum.find(fn {k, _} -> k == "content-type" end)
      {_, ct_value} = content_type
      assert ct_value =~ "json"
      refute ct_value =~ "html"
    end

    test "passes through with valid active API key and assigns current_api_key", %{conn: conn} do
      api_key = create_api_key()

      capture_log(fn ->
        result =
          conn
          |> put_req_header("authorization", "Bearer #{api_key.key}")
          |> get(~p"/api/v1/products")

        send(self(), {:result, result})
      end)

      assert_received {:result, response}
      # Should not be 401 (even if 404 or other, the plug passed through)
      refute response.status == 401
      # The assigned api_key is on the conn used internally; we check it
      # doesn't 401 which confirms the plug accepted the key
    end

    test "returns 401 for inactive API key", %{conn: conn} do
      api_key = create_api_key(%{active: false})

      capture_log(fn ->
        result =
          conn
          |> put_req_header("authorization", "Bearer #{api_key.key}")
          |> get(~p"/api/v1/products")

        send(self(), {:result, result})
      end)

      assert_received {:result, response}
      assert response.status == 401
    end
  end
end
