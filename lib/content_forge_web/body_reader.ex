defmodule ContentForgeWeb.BodyReader do
  @moduledoc """
  Custom body reader for `Plug.Parsers` that stores the raw request body
  on the connection for webhook routes that need to verify an HMAC
  signature over the exact bytes Media Forge signed.

  For non-webhook routes the body is not retained; `Plug.Parsers` still
  parses it into `body_params` as usual.
  """

  @webhook_paths ["/webhooks/media_forge"]

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, maybe_store(conn, body)}
      {:more, body, conn} -> {:more, body, maybe_store(conn, body)}
      {:error, _} = err -> err
    end
  end

  defp maybe_store(conn, chunk) do
    if conn.request_path in @webhook_paths do
      existing = conn.assigns[:raw_body] || ""
      Plug.Conn.assign(conn, :raw_body, existing <> chunk)
    else
      conn
    end
  end
end
