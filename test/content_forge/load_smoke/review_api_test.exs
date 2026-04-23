defmodule ContentForge.LoadSmoke.ReviewApiTest do
  @moduledoc """
  Proves `ContentForge.LoadSmoke.ReviewApi.run/1` round-trips
  against a live HTTP endpoint with small traffic (concurrency 2,
  total 10). Full-scale runs (concurrency 50, total 1000) are
  manual-only.

  Sandbox is shared so the Bandit request processes can see the
  seeded rows.
  """
  use ContentForge.DataCase, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias ContentForge.Accounts
  alias ContentForge.ContentGeneration
  alias ContentForge.LoadSmoke.ReviewApi
  alias ContentForge.Products
  alias ContentForge.Repo
  alias ContentForgeWeb.Endpoint
  alias Ecto.Adapters.SQL.Sandbox

  @api_key String.duplicate("L", 48)

  setup do
    Sandbox.mode(Repo, {:shared, self()})

    {:ok, product} =
      Products.create_product(%{
        name: "load-smoke-product-1",
        voice_profile: "professional",
        publishing_targets: %{
          "twitter" => %{"enabled" => true, "cadence" => "3x/week"}
        }
      })

    {:ok, draft} =
      ContentGeneration.create_draft(%{
        "product_id" => product.id,
        "content" => "load smoke draft",
        "platform" => "twitter",
        "content_type" => "post",
        "generating_model" => "load-smoke",
        "status" => "draft"
      })

    {:ok, _api_key} =
      Accounts.create_api_key(%{
        key: @api_key,
        label: "load-smoke meta-test",
        active: true
      })

    {:ok, server_pid, port} = start_test_http_server()

    on_exit(fn ->
      ref = Process.monitor(server_pid)
      Process.exit(server_pid, :shutdown)

      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        5_000 -> :ok
      end
    end)

    %{port: port, product: product, draft: draft}
  end

  test "script works with concurrency 2 and total 10", %{port: port} do
    capture_log(fn ->
      capture_io(fn ->
        result =
          ReviewApi.run(
            base_url: "http://127.0.0.1:#{port}",
            concurrency: 2,
            total: 10,
            seed: false,
            api_key: @api_key,
            n1_threshold: 20
          )

        send(self(), {:stats, result})
      end)
    end)

    assert_received {:stats, stats}

    assert stats.total_requests == 10
    assert is_integer(stats.errors)
    assert is_integer(stats.duration_ms)
    assert is_number(stats.rps)
    assert is_map(stats.errors_by_class)

    # With 10 requests spread across 5 operations, some succeed and
    # produce latency numbers. Percentiles over an empty latency
    # list are nil - the script must not crash on that path, and
    # the test DB here guarantees at least one read (GET /products)
    # succeeds.
    assert stats.p50_ms != nil
    assert stats.p95_ms != nil
    assert stats.p99_ms != nil

    # Query-count header must flow back for every successful
    # response; avg_queries_per_request being non-nil proves the
    # telemetry handler + plug wiring is live.
    assert stats.avg_queries_per_request != nil

    # N+1 tracking field is present; for this tiny seed it may be
    # zero or the query-heavy operations might trip it - either is
    # OK, we only assert the field exists and is a non-negative
    # integer.
    assert is_integer(stats.queries_over_threshold_count)
    assert stats.queries_over_threshold_count >= 0
    assert is_list(stats.queries_over_threshold)
  end

  # A small Bandit server bound to an OS-picked port using the
  # project's endpoint as the plug. The endpoint is already
  # supervised by the Application in :test, but with server: false;
  # this extra Bandit instance exposes HTTP for the meta-test only.
  defp start_test_http_server do
    {:ok, pid} =
      Bandit.start_link(
        plug: Endpoint,
        scheme: :http,
        port: 0,
        ip: {127, 0, 0, 1}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {:ok, pid, port}
  end
end
