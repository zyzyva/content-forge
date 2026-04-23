defmodule ContentForgeWeb.Plugs.TwilioSignatureVerifier do
  @moduledoc """
  Plug that verifies inbound Twilio webhooks.

  Twilio signs each webhook request with an HMAC-SHA1 of
  `url + concat(sorted(key + value))` using the account auth token as
  the key, base64-encoded, delivered in the `X-Twilio-Signature`
  header. This plug rebuilds that signature and compares via
  `Plug.Crypto.secure_compare/2`.

  Mismatch returns 403; missing header returns 400. The auth token is
  sourced from `:content_forge, :twilio, :auth_token` with env-var
  runtime wiring. If unset the plug rejects every request (fail
  closed).
  """

  import Plug.Conn
  require Logger

  @signature_header "x-twilio-signature"

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, signature} <- fetch_signature(conn),
         {:ok, token} <- fetch_auth_token(),
         :ok <- check_signature(conn, token, signature) do
      conn
    else
      {:error, :missing_signature} -> reject(conn, 400, "missing signature")
      {:error, :no_auth_token} -> reject(conn, 403, "twilio auth not configured")
      {:error, :bad_signature} -> reject(conn, 403, "invalid signature")
    end
  end

  # ---------------------------------------------------------------------------

  defp fetch_signature(conn) do
    case get_req_header(conn, @signature_header) do
      [signature] when is_binary(signature) and signature != "" -> {:ok, signature}
      _ -> {:error, :missing_signature}
    end
  end

  defp fetch_auth_token do
    case auth_token() do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :no_auth_token}
    end
  end

  defp check_signature(conn, token, provided) do
    expected = compute_signature(conn, token)

    if Plug.Crypto.secure_compare(expected, provided) do
      :ok
    else
      {:error, :bad_signature}
    end
  end

  defp compute_signature(conn, token) do
    data = webhook_url(conn) <> sorted_param_blob(conn)

    :crypto.mac(:hmac, :sha, token, data)
    |> Base.encode64()
  end

  defp webhook_url(conn) do
    scheme = Atom.to_string(conn.scheme)
    port_suffix = port_suffix(conn.scheme, conn.port)

    "#{scheme}://#{conn.host}#{port_suffix}#{conn.request_path}"
  end

  defp port_suffix(:http, 80), do: ""
  defp port_suffix(:https, 443), do: ""
  defp port_suffix(_scheme, nil), do: ""
  defp port_suffix(_scheme, port), do: ":#{port}"

  # Twilio signs POST form params sorted alphabetically by key with the
  # concatenation `k1v1k2v2...` (no separators). `body_params` are the
  # parsed form fields; any non-binary values we skip defensively.
  defp sorted_param_blob(conn) do
    conn.body_params
    |> Enum.reject(fn {_k, v} -> not is_binary(v) end)
    |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
    |> Enum.map_join(fn {k, v} -> to_string(k) <> v end)
  end

  defp auth_token do
    :content_forge
    |> Application.get_env(:twilio, [])
    |> Keyword.get(:auth_token)
  end

  defp reject(conn, status, reason) do
    Logger.warning("TwilioWebhook: rejected (#{status}) - #{reason}")

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, reason)
    |> halt()
  end
end
