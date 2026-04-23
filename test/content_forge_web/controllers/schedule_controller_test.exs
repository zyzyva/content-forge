defmodule ContentForgeWeb.ScheduleControllerTest do
  @moduledoc """
  Regression coverage for the Oban.insert shape bug in
  `schedule_for_platform/2`. Prior to the fix, the controller
  called `Oban.insert(%{...})` with a plain map, which raised
  `FunctionClauseError` instead of enqueuing anything. This test
  drives the endpoint and asserts a real `Publisher` job lands on
  the queue.
  """
  use ContentForgeWeb.ConnCase, async: true
  use Oban.Testing, repo: ContentForge.Repo

  alias ContentForge.Accounts
  alias ContentForge.ContentGeneration
  alias ContentForge.Jobs.Publisher
  alias ContentForge.Products
  alias ContentForgeWeb.ScheduleController

  @api_key String.duplicate("s", 48)

  setup %{conn: conn} do
    {:ok, _api_key} =
      Accounts.create_api_key(%{
        key: @api_key,
        label: "schedule-controller test",
        active: true
      })

    {:ok, product} =
      Products.create_product(%{
        name: "Schedule Shape Product",
        voice_profile: "professional",
        publishing_targets: %{
          "twitter" => %{"enabled" => true, "cadence" => "3x/week"},
          "linkedin" => %{"enabled" => false}
        }
      })

    authed =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{@api_key}")

    %{conn: authed, product: product}
  end

  describe "POST /api/v1/products/:id/schedule" do
    test "enqueues a Publisher job per enabled platform", %{conn: conn, product: product} do
      conn = post(conn, ~p"/api/v1/products/#{product.id}/schedule", %{})

      body = json_response(conn, 200)
      assert body["product_id"] == product.id

      twitter_row = Enum.find(body["scheduled"], &(&1["platform"] == "twitter"))
      linkedin_row = Enum.find(body["scheduled"], &(&1["platform"] == "linkedin"))

      assert twitter_row["status"] == "scheduled"
      assert linkedin_row["status"] == "disabled"

      assert_enqueued(
        worker: Publisher,
        args: %{"product_id" => product.id, "platform" => "twitter"}
      )

      refute_enqueued(
        worker: Publisher,
        args: %{"product_id" => product.id, "platform" => "linkedin"}
      )
    end

    test "respects explicit platforms list in the body", %{conn: conn, product: product} do
      conn =
        post(conn, ~p"/api/v1/products/#{product.id}/schedule", %{
          "platforms" => ["twitter"]
        })

      assert %{"scheduled" => [%{"platform" => "twitter", "status" => "scheduled"}]} =
               json_response(conn, 200)

      assert_enqueued(
        worker: Publisher,
        args: %{"product_id" => product.id, "platform" => "twitter"}
      )
    end
  end

  # publish_draft/2 and publish_now/2 aren't routed yet, so these
  # tests invoke the controller actions directly. Without the
  # 15.4.2 shape fix, both sites raised FunctionClauseError on the
  # bare-map Oban.insert call.
  describe "publish_draft/2 (action direct)" do
    test "enqueues Publisher with draft_id for an approved draft", %{product: product} do
      {:ok, draft} =
        ContentGeneration.create_draft(%{
          "product_id" => product.id,
          "content" => "approved draft",
          "platform" => "twitter",
          "content_type" => "post",
          "generating_model" => "test",
          "status" => "approved"
        })

      conn = action_conn() |> ScheduleController.publish_draft(%{"id" => draft.id})
      assert json_response(conn, 200) == %{"draft_id" => draft.id, "status" => "scheduled"}

      assert_enqueued(worker: Publisher, args: %{"draft_id" => draft.id})
    end

    test "returns :not_found when draft is missing" do
      {:error, :not_found} =
        action_conn() |> ScheduleController.publish_draft(%{"id" => Ecto.UUID.generate()})

      refute_enqueued(worker: Publisher)
    end

    test "returns :bad_request when draft is not approved", %{product: product} do
      {:ok, draft} =
        ContentGeneration.create_draft(%{
          "product_id" => product.id,
          "content" => "pending draft",
          "platform" => "twitter",
          "content_type" => "post",
          "generating_model" => "test",
          "status" => "draft"
        })

      {:error, :bad_request, _} =
        action_conn() |> ScheduleController.publish_draft(%{"id" => draft.id})

      refute_enqueued(worker: Publisher)
    end
  end

  describe "publish_now/2 (action direct)" do
    test "enqueues Publisher with draft_id regardless of draft status", %{product: product} do
      {:ok, draft} =
        ContentGeneration.create_draft(%{
          "product_id" => product.id,
          "content" => "any-status draft",
          "platform" => "twitter",
          "content_type" => "post",
          "generating_model" => "test",
          "status" => "draft"
        })

      conn = action_conn() |> ScheduleController.publish_now(%{"id" => draft.id})
      assert json_response(conn, 200) == %{"draft_id" => draft.id, "status" => "scheduled"}

      assert_enqueued(worker: Publisher, args: %{"draft_id" => draft.id})
    end

    test "returns :not_found when draft is missing" do
      {:error, :not_found} =
        action_conn() |> ScheduleController.publish_now(%{"id" => Ecto.UUID.generate()})

      refute_enqueued(worker: Publisher)
    end
  end

  defp action_conn do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("accept", "application/json")
  end
end
