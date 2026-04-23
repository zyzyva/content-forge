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
  alias ContentForge.Jobs.Publisher
  alias ContentForge.Products

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
end
