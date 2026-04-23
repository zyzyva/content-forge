defmodule ContentForgeWeb.MediaForgeWebhookController do
  @moduledoc """
  Receives signed job-completion notices from Media Forge.

  The `Plugs.MediaForgeWebhookVerifier` has already validated the HMAC
  signature and timestamp window by the time a request reaches this
  controller. Payload shape from Media Forge:

      {
        "event": "job.done" | "job.failed",
        "job":   { "id": "<media forge job id>", ... },
        "result": { ... }          # when event = job.done
        "error":  "<reason>"        # when event = job.failed
      }

  Dispatch is delegated to `ContentForge.MediaForge.JobResolver` so the
  webhook path and the polling path produce the same state transition.
  """

  use ContentForgeWeb, :controller

  alias ContentForge.MediaForge.JobResolver

  require Logger

  def handle(conn, params) do
    case parse_payload(params) do
      {:ok, job_id, event} ->
        dispatch(conn, job_id, event)

      {:error, :malformed} ->
        Logger.warning("MediaForgeWebhook: malformed payload #{inspect(params)}")

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(400, "malformed payload")
    end
  end

  defp dispatch(conn, job_id, event) do
    case JobResolver.resolve_by_job_id(job_id, event) do
      {:error, :not_found} ->
        Logger.warning("MediaForgeWebhook: unknown job id #{job_id}")

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "unknown job id")

      {:ok, _outcome} ->
        respond_ok(conn)

      {:ok, _outcome, _detail} ->
        respond_ok(conn)
    end
  end

  defp respond_ok(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(%{"ok" => true}))
  end

  defp parse_payload(%{"event" => "job.done", "job" => %{"id" => id}} = params)
       when is_binary(id) do
    result = params["result"] || %{}
    {:ok, id, {:done, result}}
  end

  defp parse_payload(%{"event" => "job.failed", "job" => %{"id" => id}} = params)
       when is_binary(id) do
    reason = params["error"] || params["message"] || "unknown"
    {:ok, id, {:failed, reason}}
  end

  defp parse_payload(_), do: {:error, :malformed}
end
