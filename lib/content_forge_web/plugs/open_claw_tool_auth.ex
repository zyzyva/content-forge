defmodule ContentForgeWeb.Plugs.OpenClawToolAuth do
  @moduledoc """
  Authenticates OpenClaw tool invocations via a shared secret.

  The OpenClaw plugin at `~/.openclaw/plugins/content-forge`
  includes an `X-OpenClaw-Tool-Secret` header on every tool
  POST. This plug compares the header against the
  `:content_forge, :open_claw_tool_secret` application env
  value using a constant-time compare.

  Fails closed: missing secret config, missing header, or
  mismatch all return 401. The secret is never logged, and the
  error body is deliberately bland so a wrong secret cannot be
  distinguished from a missing one by probing.
  """
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, expected} <- fetch_secret(),
         ["" <> got] <- get_req_header(conn, "x-openclaw-tool-secret"),
         true <- Plug.Crypto.secure_compare(expected, got) do
      conn
    else
      _ -> deny(conn)
    end
  end

  defp fetch_secret do
    case Application.get_env(:content_forge, :open_claw_tool_secret) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> :error
    end
  end

  defp deny(conn) do
    conn
    |> put_status(:unauthorized)
    |> put_view(json: ContentForgeWeb.ErrorJSON)
    |> render(:error, message: "Unauthorized")
    |> halt()
  end
end
