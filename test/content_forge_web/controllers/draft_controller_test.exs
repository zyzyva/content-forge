defmodule ContentForgeWeb.DraftControllerTest do
  use ContentForgeWeb.ConnCase

  use Oban.Testing, repo: ContentForge.Repo

  import ExUnit.CaptureLog

  alias ContentForge.Accounts
  alias ContentForge.ContentGeneration
  alias ContentForge.Products

  setup %{conn: conn} do
    {:ok, api_key} =
      Accounts.create_api_key(%{
        key: String.duplicate("a", 32),
        label: "test key",
        active: true
      })

    authed_conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{api_key.key}")

    {:ok, product} =
      Products.create_product(%{
        name: "Test Product",
        voice_profile: "professional"
      })

    %{conn: authed_conn, product: product}
  end

  defp create_draft(product, attrs \\ %{}) do
    defaults = %{
      product_id: product.id,
      content: "Test content for a draft",
      platform: "twitter",
      content_type: "post",
      generating_model: "claude"
    }

    {:ok, draft} = ContentGeneration.create_draft(Map.merge(defaults, attrs))
    draft
  end

  describe "GET /api/v1/products/:product_id/drafts" do
    test "returns 200 with list of drafts", %{conn: conn, product: product} do
      _draft = create_draft(product)

      capture_log(fn ->
        response = get(conn, ~p"/api/v1/products/#{product.id}/drafts")
        send(self(), {:response, response})
      end)

      assert_received {:response, response}
      assert %{"data" => drafts} = json_response(response, 200)
      assert length(drafts) == 1
    end

    test "returns 200 with empty list when no drafts exist", %{conn: conn, product: product} do
      capture_log(fn ->
        response = get(conn, ~p"/api/v1/products/#{product.id}/drafts")
        send(self(), {:response, response})
      end)

      assert_received {:response, response}
      assert %{"data" => drafts} = json_response(response, 200)
      assert drafts == []
    end
  end

  describe "POST /api/v1/products/:product_id/drafts" do
    test "creates a draft and returns 201", %{conn: conn, product: product} do
      draft_params = %{
        "content" => "New draft content",
        "platform" => "linkedin",
        "content_type" => "post",
        "generating_model" => "claude"
      }

      capture_log(fn ->
        response =
          post(conn, ~p"/api/v1/products/#{product.id}/drafts", %{"draft" => draft_params})

        send(self(), {:response, response})
      end)

      assert_received {:response, response}
      assert %{"data" => draft} = json_response(response, 201)
      assert draft["content"] == "New draft content"
      assert draft["platform"] == "linkedin"
    end

    test "returns 404 when product does not exist", %{conn: conn} do
      draft_params = %{
        "content" => "content",
        "platform" => "twitter",
        "content_type" => "post",
        "generating_model" => "claude"
      }

      capture_log(fn ->
        response =
          post(conn, ~p"/api/v1/products/00000000-0000-0000-0000-000000000000/drafts", %{
            "draft" => draft_params
          })

        send(self(), {:response, response})
      end)

      assert_received {:response, response}
      assert json_response(response, 404)
    end
  end

  describe "POST /api/v1/drafts/:id/approve" do
    test "with valid draft returns 200", %{conn: conn, product: product} do
      draft = create_draft(product)

      capture_log(fn ->
        response = post(conn, ~p"/api/v1/drafts/#{draft.id}/approve")
        send(self(), {:response, response})
      end)

      assert_received {:response, response}
      assert %{"data" => updated_draft} = json_response(response, 200)
      assert updated_draft["status"] == "approved"
    end

    test "returns 404 for nonexistent draft", %{conn: conn} do
      capture_log(fn ->
        response =
          post(conn, ~p"/api/v1/drafts/00000000-0000-0000-0000-000000000000/approve")

        send(self(), {:response, response})
      end)

      assert_received {:response, response}
      assert json_response(response, 404)
    end
  end

  describe "POST /api/v1/drafts/:id/reject" do
    test "without reason param returns 200 (not 500)", %{conn: conn, product: product} do
      draft = create_draft(product)

      capture_log(fn ->
        response = post(conn, ~p"/api/v1/drafts/#{draft.id}/reject", %{})
        send(self(), {:response, response})
      end)

      assert_received {:response, response}
      assert %{"data" => updated_draft} = json_response(response, 200)
      assert updated_draft["status"] == "rejected"
    end

    test "with reason param returns 200", %{conn: conn, product: product} do
      draft = create_draft(product)

      capture_log(fn ->
        response =
          post(conn, ~p"/api/v1/drafts/#{draft.id}/reject", %{"reason" => "Not on brand"})

        send(self(), {:response, response})
      end)

      assert_received {:response, response}
      assert %{"data" => updated_draft} = json_response(response, 200)
      assert updated_draft["status"] == "rejected"
    end

    test "with nonexistent id returns 404", %{conn: conn} do
      capture_log(fn ->
        response =
          post(conn, ~p"/api/v1/drafts/00000000-0000-0000-0000-000000000000/reject", %{
            "reason" => "test"
          })

        send(self(), {:response, response})
      end)

      assert_received {:response, response}
      assert json_response(response, 404)
    end
  end

  describe "POST /api/v1/products/:product_id/generate" do
    test "enqueues jobs and returns 200 when product has voice_profile", %{
      conn: conn,
      product: product
    } do
      capture_log(fn ->
        response =
          post(conn, ~p"/api/v1/products/#{product.id}/generate", %{"options" => %{}})

        send(self(), {:response, response})
      end)

      assert_received {:response, response}
      assert %{"message" => message} = json_response(response, 200)
      assert message =~ "enqueued"

      assert_enqueued(worker: ContentForge.Jobs.ContentBriefGenerator)
      assert_enqueued(worker: ContentForge.Jobs.OpenClawBulkGenerator)
    end

    test "returns 404 when product does not exist", %{conn: conn} do
      capture_log(fn ->
        response =
          post(conn, ~p"/api/v1/products/00000000-0000-0000-0000-000000000000/generate", %{
            "options" => %{}
          })

        send(self(), {:response, response})
      end)

      assert_received {:response, response}
      assert json_response(response, 404)
    end
  end
end
