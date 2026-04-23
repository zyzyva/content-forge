defmodule ContentForgeWeb.CompetitorControllerTest do
  use ContentForgeWeb.ConnCase

  alias ContentForge.Accounts
  alias ContentForge.Products

  setup %{conn: conn} do
    {:ok, api_key} =
      Accounts.create_api_key(%{
        key: String.duplicate("c", 32),
        label: "competitor test key",
        active: true
      })

    {:ok, product} =
      Products.create_product(%{name: "Test Product", voice_profile: "professional"})

    authed_conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{api_key.key}")

    %{conn: authed_conn, product: product}
  end

  describe "POST /api/v1/products/:product_id/competitors" do
    test "creates a competitor account and returns it", %{conn: conn, product: product} do
      params = %{
        "competitor" => %{
          "platform" => "twitter",
          "handle" => "acme",
          "url" => "https://twitter.com/acme",
          "active" => true
        }
      }

      conn = post(conn, ~p"/api/v1/products/#{product.id}/competitors", params)

      assert %{"data" => data} = json_response(conn, 201)
      assert data["platform"] == "twitter"
      assert data["handle"] == "acme"
      assert data["product_id"] == product.id
      assert data["active"] == true
    end

    test "returns 422 with invalid params", %{conn: conn, product: product} do
      params = %{"competitor" => %{"platform" => "twitter"}}
      conn = post(conn, ~p"/api/v1/products/#{product.id}/competitors", params)
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "GET /api/v1/products/:product_id/competitors" do
    test "lists only this product's competitor accounts", %{conn: conn, product: product} do
      {:ok, mine} =
        Products.create_competitor_account(%{
          product_id: product.id,
          platform: "linkedin",
          handle: "mine",
          url: "https://linkedin.com/in/mine",
          active: true
        })

      {:ok, other_product} =
        Products.create_product(%{name: "Other Product", voice_profile: "casual"})

      {:ok, _other} =
        Products.create_competitor_account(%{
          product_id: other_product.id,
          platform: "linkedin",
          handle: "other",
          url: "https://linkedin.com/in/other",
          active: true
        })

      conn = get(conn, ~p"/api/v1/products/#{product.id}/competitors")
      assert %{"data" => data} = json_response(conn, 200)
      ids = Enum.map(data, & &1["id"])
      assert mine.id in ids
      assert length(data) == 1
    end
  end

  describe "GET /api/v1/products/:product_id/competitors/:id" do
    test "returns the competitor account", %{conn: conn, product: product} do
      {:ok, account} =
        Products.create_competitor_account(%{
          product_id: product.id,
          platform: "twitter",
          handle: "acme",
          url: "https://twitter.com/acme",
          active: true
        })

      conn = get(conn, ~p"/api/v1/products/#{product.id}/competitors/#{account.id}")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == account.id
      assert data["handle"] == "acme"
    end
  end

  describe "DELETE /api/v1/products/:product_id/competitors/:id" do
    test "deletes the competitor account", %{conn: conn, product: product} do
      {:ok, account} =
        Products.create_competitor_account(%{
          product_id: product.id,
          platform: "twitter",
          handle: "acme",
          url: "https://twitter.com/acme",
          active: true
        })

      conn = delete(conn, ~p"/api/v1/products/#{product.id}/competitors/#{account.id}")
      assert response(conn, 204)
      assert Products.list_competitor_accounts_for_product(product.id) == []
    end
  end

  describe "auth" do
    test "rejects requests without a bearer token", %{conn: _conn, product: product} do
      bare =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("accept", "application/json")

      conn = get(bare, ~p"/api/v1/products/#{product.id}/competitors")
      assert response(conn, 401)
    end
  end
end
