defmodule ContentForge.Twilio do
  @moduledoc """
  HTTP client for Twilio's Messages API.

  Every Content Forge caller that needs to send an SMS or MMS goes
  through this module. It centralises the base URL, HTTP Basic auth
  (account SID + auth token), request body construction,
  error classification, and `Req.Test` stubbing. Nothing else in the
  codebase should build raw HTTP requests against Twilio's REST API.

  ## Configuration

      config :content_forge, :twilio,
        base_url: "https://api.twilio.com",
        account_sid: System.get_env("TWILIO_ACCOUNT_SID"),
        auth_token: System.get_env("TWILIO_AUTH_TOKEN"),
        from_number: System.get_env("TWILIO_FROM_NUMBER"),
        default_messaging_service_sid:
          System.get_env("TWILIO_MESSAGING_SERVICE_SID")

  Every required field is sourced from env at runtime. A field is
  required iff `status/0` considers it so: `account_sid`, `auth_token`,
  and at least one of `from_number` / `default_messaging_service_sid`.
  When any required field is missing, `status/0` reports
  `:not_configured` and every call returns `{:error, :not_configured}`
  with zero HTTP I/O so callers can downgrade gracefully.

  `default_messaging_service_sid` is preferred over `from_number` when
  both are set, mirroring Twilio's own precedence.

  ## Return shapes

  On success `send_sms/3` returns `{:ok, %{sid: binary, status: binary}}`
  where `sid` is Twilio's message SID and `status` is one of
  `"queued"`, `"sending"`, `"sent"`, `"failed"`, etc. per Twilio's
  delivery-status taxonomy.

  On failure the error tuple is classified, matching the established
  `ContentForge.MediaForge` / `ContentForge.LLM.Anthropic` /
  `ContentForge.LLM.Gemini` / `ContentForge.OpenClaw` pattern:

    * `{:error, :not_configured}`
    * `{:error, {:transient, status, body}}` - 5xx or 429
    * `{:error, {:transient, :timeout, reason}}`
    * `{:error, {:transient, :network, reason}}` - econnrefused, etc.
    * `{:error, {:http_error, status, body}}` - other 4xx
    * `{:error, {:unexpected_status, status, body}}` - 3xx
    * `{:error, reason}` - anything else
  """

  require Logger

  @config_app :content_forge
  @config_key :twilio

  @default_base_url "https://api.twilio.com"

  @type send_opt ::
          {:media_urls, [String.t()]}
          | {:from, String.t()}
          | {:messaging_service_sid, String.t()}
  @type send_opts :: [send_opt()]
  @type ok_result :: {:ok, %{sid: String.t(), status: String.t()}}
  @type error_result ::
          {:error, :not_configured}
          | {:error, {:transient, non_neg_integer() | atom(), any()}}
          | {:error, {:http_error, non_neg_integer(), any()}}
          | {:error, {:unexpected_status, non_neg_integer(), any()}}
          | {:error, any()}

  @doc "Returns `:ok` when all required credentials are set, `:not_configured` otherwise."
  @spec status() :: :ok | :not_configured
  def status do
    config_status(fetch_account_sid(), fetch_auth_token(), default_sender_configured?())
  end

  defp config_status(sid, token, sender_ok) do
    if present?(sid) and present?(token) and sender_ok do
      :ok
    else
      :not_configured
    end
  end

  defp default_sender_configured? do
    present?(fetch_from_number()) or present?(fetch_messaging_service_sid())
  end

  @doc """
  Sends an SMS or MMS via Twilio.

  Options:

    * `:media_urls` - a list of `String.t()` media URLs; when non-empty
      the message is sent as MMS with each URL attached as a `MediaUrl`
      form parameter.
    * `:from` - overrides the configured `from_number` for this call.
    * `:messaging_service_sid` - overrides the configured
      `default_messaging_service_sid` for this call. When set (or when
      the default is set) the request uses `MessagingServiceSid`
      instead of `From`.
  """
  @spec send_sms(String.t(), String.t(), send_opts()) :: ok_result() | error_result()
  def send_sms(to, body, opts \\ []) when is_binary(to) and is_binary(body) do
    dispatch(to, body, opts, fetch_account_sid(), fetch_auth_token())
  end

  # --- dispatch ------------------------------------------------------------

  defp dispatch(_to, _body, _opts, sid, _token) when sid in [nil, ""],
    do: {:error, :not_configured}

  defp dispatch(_to, _body, _opts, _sid, token) when token in [nil, ""],
    do: {:error, :not_configured}

  defp dispatch(to, body, opts, account_sid, auth_token) do
    case resolve_sender(opts) do
      {:error, :not_configured} = err ->
        err

      {:ok, sender} ->
        form_body = build_form_body(to, body, sender, opts)

        account_sid
        |> build_request(auth_token)
        |> Req.post(form: form_body)
        |> classify()
    end
  end

  # --- sender resolution --------------------------------------------------

  defp resolve_sender(opts) do
    service_sid = Keyword.get(opts, :messaging_service_sid) || fetch_messaging_service_sid()
    resolve_sender(opts, service_sid)
  end

  defp resolve_sender(_opts, sid) when is_binary(sid) and sid != "",
    do: {:ok, {:service_sid, sid}}

  defp resolve_sender(opts, _sid), do: resolve_from(opts)

  defp resolve_from(opts) do
    case Keyword.get(opts, :from) || fetch_from_number() do
      from when is_binary(from) and from != "" -> {:ok, {:from, from}}
      _ -> {:error, :not_configured}
    end
  end

  # --- request construction -----------------------------------------------

  defp build_request(account_sid, auth_token) do
    base = [
      url: "/2010-04-01/Accounts/#{account_sid}/Messages.json",
      base_url: base_url(),
      auth: {:basic, "#{account_sid}:#{auth_token}"},
      receive_timeout: 30_000,
      retry: false,
      redirect: false
    ]

    Req.new(base ++ extra_req_options())
  end

  # Twilio accepts repeated keys in a form-urlencoded body for media
  # URLs. Req's :form option takes a list of {key, value} tuples and
  # preserves duplicates, so we keep each MediaUrl as its own tuple.
  defp build_form_body(to, body, sender, opts) do
    base = [
      {"To", to},
      {"Body", body},
      sender_pair(sender)
    ]

    base ++ media_url_pairs(Keyword.get(opts, :media_urls, []))
  end

  defp sender_pair({:service_sid, sid}), do: {"MessagingServiceSid", sid}
  defp sender_pair({:from, from}), do: {"From", from}

  defp media_url_pairs(nil), do: []
  defp media_url_pairs([]), do: []

  defp media_url_pairs(urls) when is_list(urls) do
    urls
    |> Enum.filter(&is_binary/1)
    |> Enum.map(fn url -> {"MediaUrl", url} end)
  end

  # --- response classification --------------------------------------------

  defp classify({:ok, %Req.Response{status: status, body: body}}) when status in 200..299 do
    parse_success(body)
  end

  defp classify({:ok, %Req.Response{status: status, body: body}}) when status in 300..399 do
    {:error, {:unexpected_status, status, body}}
  end

  defp classify({:ok, %Req.Response{status: 429, body: body}}) do
    {:error, {:transient, 429, body}}
  end

  defp classify({:ok, %Req.Response{status: status, body: body}}) when status in 400..499 do
    {:error, {:http_error, status, body}}
  end

  defp classify({:ok, %Req.Response{status: status, body: body}}) when status >= 500 do
    {:error, {:transient, status, body}}
  end

  defp classify({:error, %Req.TransportError{reason: :timeout} = err}) do
    {:error, {:transient, :timeout, err.reason}}
  end

  defp classify({:error, %Req.TransportError{reason: reason}})
       when reason in [:econnrefused, :nxdomain, :ehostunreach, :enetunreach, :closed] do
    {:error, {:transient, :network, reason}}
  end

  defp classify({:error, reason}), do: {:error, reason}

  defp parse_success(%{"sid" => sid, "status" => status})
       when is_binary(sid) and is_binary(status) do
    {:ok, %{sid: sid, status: status}}
  end

  defp parse_success(body), do: {:error, {:unexpected_body, body}}

  # --- config -------------------------------------------------------------

  defp base_url, do: config(:base_url) || @default_base_url
  defp fetch_account_sid, do: config(:account_sid)
  defp fetch_auth_token, do: config(:auth_token)
  defp fetch_from_number, do: config(:from_number)
  defp fetch_messaging_service_sid, do: config(:default_messaging_service_sid)
  defp extra_req_options, do: config(:req_options) || []

  defp config(key) do
    @config_app
    |> Application.get_env(@config_key, [])
    |> Keyword.get(key)
  end

  defp present?(value) when is_binary(value) and value != "", do: true
  defp present?(_), do: false
end
