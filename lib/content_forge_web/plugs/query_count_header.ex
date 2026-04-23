defmodule ContentForgeWeb.Plugs.QueryCountHeader do
  @moduledoc """
  Counts the number of Ecto queries executed while handling the
  current HTTP request, then emits the count as an
  `x-cf-query-count` response header. Load-smoke tooling
  (`ContentForge.LoadSmoke.ReviewApi`) reads this header to flag
  N+1 hotspots.

  Correlation is per-process: Phoenix dispatches each request in a
  dedicated process, and Ecto telemetry fires in the process that
  issued the query. The plug resets the counter in the process
  dictionary on entry and reads it in `register_before_send`.

  The handler that increments the counter is attached once in
  `ContentForge.Application.start/2`. Cost is one Process.put call
  per query - negligible.

  Detaching during request bodies (e.g. async tasks spawned from
  the controller) is out of scope: only queries executed on the
  request process are counted.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    Process.put(:cf_query_count, 0)

    register_before_send(conn, fn conn ->
      count = Process.get(:cf_query_count, 0)
      put_resp_header(conn, "x-cf-query-count", Integer.to_string(count))
    end)
  end

  @doc """
  Attaches the telemetry handler that increments the per-process
  query counter on every Ecto query. Idempotent: re-attaching
  with the same handler id is a no-op (handled by telemetry).
  """
  def attach_telemetry do
    :telemetry.attach(
      "content-forge-query-count",
      [:content_forge, :repo, :query],
      &__MODULE__.handle_query_event/4,
      nil
    )
  end

  def handle_query_event(_event, _measurements, _metadata, _config) do
    Process.put(:cf_query_count, (Process.get(:cf_query_count) || 0) + 1)
  end
end
