defmodule ContentForgeWeb.Plugs.MediaForgeWebhookVerifier do
  @moduledoc """
  Plug that verifies inbound Media Forge webhooks.

  Validates the `X-MediaForge-Signature` header with the Stripe-style shape
  `t=<unix-timestamp>,v1=<hex>` against the raw request body (captured by
  `ContentForgeWeb.BodyReader`) using HMAC-SHA256 with the configured
  shared secret. A 300-second timestamp window on either side of server
  time is enforced. Signatures are compared via `Plug.Crypto.secure_compare/2`
  to avoid timing-leak side channels.

  On any failure the plug halts the connection with the appropriate status
  (400 for malformed or stale payloads, 401 for bad or missing signatures)
  and a short plain-text reason. The offending signature is never echoed.

  Configuration: `config :content_forge, :media_forge, webhook_secret: <binary>`
  or reuses `:secret` if `:webhook_secret` is not set. When no secret is
  configured every inbound request is rejected with 401.
  """

  import Plug.Conn
  require Logger

  @timestamp_window_seconds 300
  @signature_header "x-mediaforge-signature"

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, body} <- fetch_raw_body(conn),
         {:ok, ts, signature} <- parse_signature_header(conn),
         :ok <- check_timestamp(ts),
         :ok <- check_signature(ts, body, signature) do
      conn
    else
      {:error, :missing_body} -> reject(conn, 400, "missing request body")
      {:error, :missing_signature} -> reject(conn, 401, "missing signature")
      {:error, :malformed_signature} -> reject(conn, 401, "invalid signature")
      {:error, :bad_timestamp} -> reject(conn, 400, "invalid timestamp")
      {:error, :stale_timestamp} -> reject(conn, 400, "stale request")
      {:error, :bad_signature} -> reject(conn, 401, "invalid signature")
      {:error, :no_secret} -> reject(conn, 401, "invalid signature")
    end
  end

  # ---------------------------------------------------------------------------

  defp fetch_raw_body(conn) do
    case conn.assigns[:raw_body] do
      body when is_binary(body) and body != "" -> {:ok, body}
      _ -> {:error, :missing_body}
    end
  end

  defp parse_signature_header(conn) do
    case get_req_header(conn, @signature_header) do
      [header] -> parse_signature_value(header)
      _ -> {:error, :missing_signature}
    end
  end

  defp parse_signature_value(header) when is_binary(header) do
    parts =
      header
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.into(%{}, &split_pair/1)

    with {:ok, ts_str} <- Map.fetch(parts, "t") |> to_result(:malformed_signature),
         {:ok, sig_hex} <- Map.fetch(parts, "v1") |> to_result(:malformed_signature),
         {ts, ""} <- Integer.parse(ts_str) do
      {:ok, ts, sig_hex}
    else
      _ -> {:error, :malformed_signature}
    end
  end

  defp split_pair(pair) do
    case String.split(pair, "=", parts: 2) do
      [key, value] -> {key, value}
      _ -> {pair, ""}
    end
  end

  defp to_result(:error, reason), do: {:error, reason}
  defp to_result({:ok, _} = ok, _reason), do: ok

  defp check_timestamp(ts) do
    now = System.system_time(:second)

    if abs(now - ts) <= @timestamp_window_seconds do
      :ok
    else
      {:error, :stale_timestamp}
    end
  end

  defp check_signature(ts, body, provided_hex) do
    case webhook_secret() do
      nil ->
        {:error, :no_secret}

      "" ->
        {:error, :no_secret}

      secret ->
        expected = compute_signature(secret, ts, body)

        if Plug.Crypto.secure_compare(expected, String.downcase(provided_hex)) do
          :ok
        else
          {:error, :bad_signature}
        end
    end
  end

  defp compute_signature(secret, ts, body) do
    :crypto.mac(:hmac, :sha256, secret, "#{ts}.#{body}")
    |> Base.encode16(case: :lower)
  end

  defp webhook_secret do
    cfg = Application.get_env(:content_forge, :media_forge, [])
    Keyword.get(cfg, :webhook_secret) || Keyword.get(cfg, :secret)
  end

  defp reject(conn, status, reason) do
    Logger.warning("MediaForgeWebhook: rejected (#{status}) - #{reason}")

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, reason)
    |> halt()
  end
end
