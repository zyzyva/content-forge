defmodule ContentForge.LoadSmoke.ReviewApi do
  @moduledoc """
  Manual-run load smoke for the Review API and publishing endpoints.

  **Not** part of CI. Invoke explicitly from a dev or load-env
  shell with a live endpoint reachable at `base_url`:

      MIX_ENV=dev iex -S mix
      iex> ContentForge.LoadSmoke.ReviewApi.run()

  ... or via the top-level script:

      MIX_ENV=dev mix run test/load/review_api_smoke.exs

  Configuration (env vars, or explicit `opts` to `run/1`):

    * `REVIEW_SMOKE_BASE_URL` - default `http://localhost:4000`
    * `REVIEW_SMOKE_CONCURRENCY` - default `50`
    * `REVIEW_SMOKE_TOTAL` - default `1000`
    * `REVIEW_SMOKE_N1_THRESHOLD` - default `20` queries/request
    * `REVIEW_SMOKE_SEED` - default `1`; set `0` to skip seeding
    * `REVIEW_SMOKE_API_KEY` - if set, skips auto-creation
    * `REVIEW_SMOKE_SEED_PRODUCTS` - default `100`
    * `REVIEW_SMOKE_SEED_DRAFTS_PER_PRODUCT` - default `50`

  The seed is idempotent: products are upserted by name
  (`load-smoke-product-<n>`) and drafts are only created if the
  product has fewer than the target count. Running the script ten
  times does not create 1000 products.

  Output: a summary map printed via `IO.puts` plus the same map
  returned from `run/1`. Fields:

    * `:total_requests`, `:errors`, `:errors_by_class`
    * `:duration_ms`, `:rps`
    * `:p50_ms`, `:p95_ms`, `:p99_ms`
    * `:avg_queries_per_request`
    * `:queries_over_threshold_count`
    * `:queries_over_threshold` (sample of the worst offenders,
      capped at 10)

  The N+1 detection reads the `x-cf-query-count` response header
  emitted by `ContentForgeWeb.Plugs.QueryCountHeader`. Any request
  whose server-side query count exceeds the threshold lands in
  `:queries_over_threshold`.
  """

  alias ContentForge.Accounts
  alias ContentForge.ContentGeneration
  alias ContentForge.Products

  @default_base_url "http://localhost:4000"
  @default_concurrency 50
  @default_total 1000
  @default_n1_threshold 20
  @default_seed_products 100
  @default_seed_drafts_per_product 50
  @http_timeout_ms 30_000

  @doc """
  Runs the load smoke. See module docs for options.
  """
  def run(opts \\ []) do
    opts = merge_env(opts)
    config = build_config(opts)

    if config.seed?, do: seed(config)

    api_key_token = get_or_create_api_key(config)
    fixtures = load_fixture_ids(config)

    case fixtures do
      {:error, :no_fixtures} ->
        IO.puts(:stderr, """
        load-smoke: no seeded products or drafts found. Run with
        REVIEW_SMOKE_SEED=1 (the default) or pre-seed the DB.
        """)

        %{error: :no_fixtures}

      %{} = fixtures ->
        run_burst(config, api_key_token, fixtures)
    end
  end

  # ---- configuration ------------------------------------------------

  defp merge_env(opts) do
    opts
    |> Keyword.put_new_lazy(:base_url, fn ->
      System.get_env("REVIEW_SMOKE_BASE_URL", @default_base_url)
    end)
    |> Keyword.put_new_lazy(:concurrency, fn ->
      int_env("REVIEW_SMOKE_CONCURRENCY", @default_concurrency)
    end)
    |> Keyword.put_new_lazy(:total, fn ->
      int_env("REVIEW_SMOKE_TOTAL", @default_total)
    end)
    |> Keyword.put_new_lazy(:n1_threshold, fn ->
      int_env("REVIEW_SMOKE_N1_THRESHOLD", @default_n1_threshold)
    end)
    |> Keyword.put_new_lazy(:seed, fn ->
      System.get_env("REVIEW_SMOKE_SEED", "1") != "0"
    end)
    |> Keyword.put_new_lazy(:api_key, fn ->
      System.get_env("REVIEW_SMOKE_API_KEY")
    end)
    |> Keyword.put_new_lazy(:seed_products, fn ->
      int_env("REVIEW_SMOKE_SEED_PRODUCTS", @default_seed_products)
    end)
    |> Keyword.put_new_lazy(:seed_drafts_per_product, fn ->
      int_env(
        "REVIEW_SMOKE_SEED_DRAFTS_PER_PRODUCT",
        @default_seed_drafts_per_product
      )
    end)
  end

  defp build_config(opts) do
    %{
      base_url: Keyword.fetch!(opts, :base_url),
      concurrency: Keyword.fetch!(opts, :concurrency),
      total: Keyword.fetch!(opts, :total),
      n1_threshold: Keyword.fetch!(opts, :n1_threshold),
      seed?: Keyword.fetch!(opts, :seed),
      api_key: Keyword.get(opts, :api_key),
      seed_products: Keyword.fetch!(opts, :seed_products),
      seed_drafts_per_product: Keyword.fetch!(opts, :seed_drafts_per_product)
    }
  end

  defp int_env(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> String.to_integer(value)
    end
  end

  # ---- seeding ------------------------------------------------------

  @doc false
  def seed(config) do
    for n <- 1..config.seed_products do
      ensure_seeded_product(n, config.seed_drafts_per_product)
    end

    :ok
  end

  defp ensure_seeded_product(n, drafts_target) do
    name = seeded_product_name(n)

    product =
      case Products.get_product_by_name(name) do
        nil ->
          {:ok, p} =
            Products.create_product(%{
              name: name,
              voice_profile: "professional"
            })

          p

        existing ->
          existing
      end

    top_up_drafts(product, drafts_target)
  end

  defp top_up_drafts(product, target) do
    current = ContentGeneration.count_drafts_for_product(product.id)
    missing = max(target - current, 0)

    if missing > 0 do
      for i <- 1..missing do
        ContentGeneration.create_draft(%{
          "product_id" => product.id,
          "content" => "load-smoke draft #{product.id}-#{current + i}",
          "platform" => "twitter",
          "content_type" => "post",
          "generating_model" => "load-smoke",
          "status" => "draft"
        })
      end
    end

    :ok
  end

  defp seeded_product_name(n), do: "load-smoke-product-#{n}"

  # ---- fixtures -----------------------------------------------------

  defp load_fixture_ids(_config) do
    product_ids =
      Products.list_products()
      |> Enum.map(& &1.id)

    draft_ids =
      ContentGeneration.list_recent_draft_ids(500)

    cond do
      product_ids == [] -> {:error, :no_fixtures}
      draft_ids == [] -> {:error, :no_fixtures}
      true -> %{product_ids: product_ids, draft_ids: draft_ids}
    end
  end

  # ---- api key ------------------------------------------------------

  defp get_or_create_api_key(%{api_key: token}) when is_binary(token) and token != "" do
    token
  end

  defp get_or_create_api_key(_config) do
    token = "load-smoke-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    {:ok, _} =
      Accounts.create_api_key(%{
        key: token,
        label: "load-smoke #{DateTime.utc_now() |> DateTime.to_iso8601()}",
        active: true
      })

    token
  end

  # ---- burst --------------------------------------------------------

  defp run_burst(config, api_key_token, fixtures) do
    started_at = System.monotonic_time(:millisecond)

    results =
      1..config.total
      |> Task.async_stream(
        fn i -> execute_request(i, config, api_key_token, fixtures) end,
        max_concurrency: config.concurrency,
        timeout: @http_timeout_ms + 5_000,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.map(&normalize_stream_result/1)

    duration_ms = System.monotonic_time(:millisecond) - started_at

    stats = summarize(results, duration_ms, config.n1_threshold)
    IO.puts(format_summary(stats))
    stats
  end

  defp normalize_stream_result({:ok, result}), do: result

  defp normalize_stream_result({:exit, reason}) do
    %{
      operation: :unknown,
      status: nil,
      error: {:exit, reason},
      latency_ms: nil,
      query_count: nil
    }
  end

  @operations [:list_products, :list_drafts, :score, :approve, :schedule]

  defp execute_request(index, config, api_key_token, fixtures) do
    op = Enum.at(@operations, rem(index, length(@operations)))
    started = System.monotonic_time(:microsecond)

    response =
      case perform_op(op, config.base_url, api_key_token, fixtures) do
        {:ok, resp} -> {:ok, resp}
        {:error, reason} -> {:error, reason}
      end

    latency_us = System.monotonic_time(:microsecond) - started

    build_result(op, response, latency_us)
  end

  defp build_result(op, {:ok, %{status: status, headers: headers}}, latency_us) do
    %{
      operation: op,
      status: status,
      error: nil,
      latency_ms: latency_us / 1000,
      query_count: query_count_from_headers(headers)
    }
  end

  defp build_result(op, {:error, reason}, latency_us) do
    %{
      operation: op,
      status: nil,
      error: reason,
      latency_ms: latency_us / 1000,
      query_count: nil
    }
  end

  defp query_count_from_headers(headers) do
    with {_k, value} <-
           Enum.find(headers, fn {k, _} ->
             String.downcase(to_string(k)) == "x-cf-query-count"
           end),
         {count, ""} <- Integer.parse(to_string(value)) do
      count
    else
      _ -> nil
    end
  end

  # ---- per-op HTTP --------------------------------------------------

  defp perform_op(:list_products, base_url, token, _fixtures) do
    request(:get, base_url, "/api/v1/products", token)
  end

  defp perform_op(:list_drafts, base_url, token, fixtures) do
    product_id = Enum.random(fixtures.product_ids)
    request(:get, base_url, "/api/v1/products/#{product_id}/drafts", token)
  end

  defp perform_op(:score, base_url, token, fixtures) do
    draft_id = Enum.random(fixtures.draft_ids)

    body = %{
      "model_name" => "load-smoke-model",
      "score" => %{
        "accuracy_score" => 7.5,
        "seo_score" => 7.0,
        "eev_score" => 6.5,
        "composite_score" => 7.2,
        "critique" => "load smoke critique"
      }
    }

    request(:post, base_url, "/api/v1/drafts/#{draft_id}/score", token, body)
  end

  defp perform_op(:approve, base_url, token, fixtures) do
    draft_id = Enum.random(fixtures.draft_ids)
    request(:post, base_url, "/api/v1/drafts/#{draft_id}/approve", token, %{})
  end

  defp perform_op(:schedule, base_url, token, fixtures) do
    product_id = Enum.random(fixtures.product_ids)

    body = %{"platforms" => ["twitter"]}

    request(
      :post,
      base_url,
      "/api/v1/products/#{product_id}/schedule",
      token,
      body
    )
  end

  defp request(method, base_url, path, token, body \\ nil) do
    opts = [
      method: method,
      url: base_url <> path,
      headers: [
        {"authorization", "Bearer #{token}"},
        {"accept", "application/json"}
      ],
      receive_timeout: @http_timeout_ms,
      connect_options: [timeout: @http_timeout_ms],
      retry: false,
      decode_body: false
    ]

    opts = if body, do: Keyword.put(opts, :json, body), else: opts

    case Req.request(opts) do
      {:ok, %Req.Response{status: status, headers: headers}} ->
        {:ok, %{status: status, headers: headers}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---- summary ------------------------------------------------------

  @doc false
  def summarize(results, duration_ms, n1_threshold) do
    total = length(results)

    {ok, errored} =
      Enum.split_with(results, fn r ->
        is_integer(r.status) and r.status < 400 and is_nil(r.error)
      end)

    latencies =
      ok
      |> Enum.map(& &1.latency_ms)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    errors_by_class =
      errored
      |> Enum.reduce(%{}, fn r, acc ->
        class = error_class(r)
        Map.update(acc, class, 1, &(&1 + 1))
      end)

    query_counts =
      results
      |> Enum.map(& &1.query_count)
      |> Enum.reject(&is_nil/1)

    over_threshold =
      results
      |> Enum.filter(fn r ->
        is_integer(r.query_count) and r.query_count > n1_threshold
      end)
      |> Enum.sort_by(& &1.query_count, :desc)
      |> Enum.take(10)
      |> Enum.map(fn r ->
        %{operation: r.operation, queries: r.query_count, status: r.status}
      end)

    rps =
      case duration_ms do
        0 -> 0.0
        ms -> total * 1000 / ms
      end

    %{
      total_requests: total,
      errors: length(errored),
      errors_by_class: errors_by_class,
      duration_ms: duration_ms,
      rps: rps,
      p50_ms: percentile(latencies, 50),
      p95_ms: percentile(latencies, 95),
      p99_ms: percentile(latencies, 99),
      avg_queries_per_request: average(query_counts),
      queries_over_threshold_count: length(over_threshold),
      queries_over_threshold: over_threshold,
      threshold: n1_threshold
    }
  end

  defp error_class(%{status: status}) when is_integer(status) and status >= 500, do: :"5xx"
  defp error_class(%{status: status}) when is_integer(status) and status >= 400, do: :"4xx"
  defp error_class(%{error: {:exit, _}}), do: :timeout
  defp error_class(%{error: reason}) when not is_nil(reason), do: :transport
  defp error_class(_), do: :unknown

  defp percentile([], _), do: nil

  defp percentile(sorted, p) do
    len = length(sorted)
    idx = max(0, min(len - 1, trunc(Float.ceil(p / 100 * len)) - 1))
    Enum.at(sorted, idx)
  end

  defp average([]), do: nil

  defp average(nums) do
    Enum.sum(nums) / length(nums)
  end

  # ---- formatting ---------------------------------------------------

  @doc false
  def format_summary(stats) do
    """
    ===============================================
    Review API load smoke summary
    ===============================================
    total_requests      #{stats.total_requests}
    errors              #{stats.errors}
    errors_by_class     #{inspect(stats.errors_by_class)}
    duration_ms         #{stats.duration_ms}
    rps                 #{Float.round(stats.rps * 1.0, 2)}
    p50_ms              #{format_float(stats.p50_ms)}
    p95_ms              #{format_float(stats.p95_ms)}
    p99_ms              #{format_float(stats.p99_ms)}
    avg_queries/req     #{format_float(stats.avg_queries_per_request)}
    n+1 threshold       #{stats.threshold}
    queries>threshold   #{stats.queries_over_threshold_count}
    top offenders       #{format_offenders(stats.queries_over_threshold)}
    ===============================================
    """
  end

  defp format_float(nil), do: "-"
  defp format_float(n) when is_integer(n), do: Integer.to_string(n)
  defp format_float(n) when is_float(n), do: Float.to_string(Float.round(n, 2))

  defp format_offenders([]), do: "none"

  defp format_offenders(list) do
    Enum.map_join(list, ", ", fn %{operation: op, queries: q, status: s} ->
      "#{op}:#{q}q/#{s}"
    end)
  end
end
