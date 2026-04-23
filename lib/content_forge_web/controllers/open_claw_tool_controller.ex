defmodule ContentForgeWeb.OpenClawToolController do
  @moduledoc """
  HTTP surface for OpenClaw agent tool invocations.

  Route: `POST /api/v1/openclaw/tools/:tool_name`

  Auth: `ContentForgeWeb.Plugs.OpenClawToolAuth` via the
  `X-OpenClaw-Tool-Secret` header. Fails closed.

  Request body shape (from the Node plugin):

      {
        "session_id": "agent-session-abc",
        "channel": "sms" | "cli" | ...,
        "sender_identity": "+15551234567" | "cli:ops",
        "params": { ... tool-specific fields ... }
      }

  Response:

      200 - {"status": "ok", "result": { ... tool payload ... }}
      404 - {"status": "error", "error": "unknown_tool"}
      422 - {"status": "error", "error": <classified reason>}

  Pattern: the controller does not do tool-specific logic. It
  builds the invocation context, delegates to
  `ContentForge.OpenClawTools.dispatch/3`, and serializes the
  result.
  """
  use ContentForgeWeb, :controller

  alias ContentForge.OpenClawTools

  def invoke(conn, %{"tool_name" => tool_name} = params) do
    ctx = build_ctx(params)
    tool_params = Map.get(params, "params", %{})

    case OpenClawTools.dispatch(tool_name, ctx, tool_params) do
      {:ok, result} ->
        json(conn, %{"status" => "ok", "result" => serialize_result(result)})

      {:error, :unknown_tool} ->
        conn
        |> put_status(:not_found)
        |> json(%{"status" => "error", "error" => "unknown_tool", "tool_name" => tool_name})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"status" => "error", "error" => reason_to_string(reason)})
    end
  end

  defp build_ctx(params) do
    %{
      session_id: Map.get(params, "session_id"),
      channel: Map.get(params, "channel"),
      sender_identity: Map.get(params, "sender_identity")
    }
  end

  defp serialize_result(result) when is_map(result) do
    # Ensure atom-keyed maps serialize to string-keyed JSON.
    Map.new(result, fn {k, v} -> {to_string(k), serialize_value(v)} end)
  end

  defp serialize_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_value(v), do: v

  defp reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_string({kind, details}) when is_atom(kind), do: "#{kind}: #{inspect(details)}"
  defp reason_to_string(other), do: inspect(other)
end
