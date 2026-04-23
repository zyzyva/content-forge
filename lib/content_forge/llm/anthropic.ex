defmodule ContentForge.LLM.Anthropic do
  @moduledoc """
  HTTP client for Anthropic's Messages API.

  Every Content Forge caller that needs a Claude completion goes through
  this module. It centralises the base URL, the `x-api-key` and
  `anthropic-version` headers, request body construction, error
  classification, and `Req.Test` stubbing. Nothing else in the codebase
  should build raw HTTP requests against the Anthropic API.

  ## Configuration

      config :content_forge, :llm,
        anthropic: [
          base_url: "https://api.anthropic.com",
          api_key: System.get_env("ANTHROPIC_API_KEY"),
          default_model: "claude-sonnet-4-6",
          max_tokens: 4096
        ]

  The API key is required; when it is missing, `status/0` reports
  `:not_configured` and every call returns `{:error, :not_configured}`
  with zero HTTP I/O so callers can downgrade gracefully.

  ## Return shapes

  On success `complete/2` returns
  `{:ok, %{text: binary, model: binary, stop_reason: binary, usage: map}}`.

  On failure the error tuple is classified:

    * `{:error, :not_configured}` -api key is unset
    * `{:error, {:transient, status, body}}` -5xx or 429 response
    * `{:error, {:transient, :timeout, reason}}` -HTTP timeout
    * `{:error, {:transient, :network, reason}}` -connect refused, DNS,
      or other network-layer error
    * `{:error, {:http_error, status, body}}` -other 4xx; do not retry
      without changing the input
    * `{:error, {:unexpected_status, status, body}}` -3xx response that
      reached the classifier
    * `{:error, reason}` -anything else, inspect reason for diagnosis
  """

  require Logger

  @config_app :content_forge
  @config_key :llm
  @provider :anthropic

  @default_base_url "https://api.anthropic.com"
  @default_model "claude-sonnet-4-6"
  @default_max_tokens 4096
  @default_anthropic_version "2023-06-01"

  @type message :: %{required(:role) => String.t(), required(:content) => String.t()}
  @type prompt :: String.t() | [message()]
  @type option ::
          {:model, String.t()}
          | {:max_tokens, pos_integer()}
          | {:temperature, number()}
          | {:system, String.t()}
  @type opts :: [option()]
  @type ok_result ::
          {:ok, %{text: String.t(), model: String.t(), stop_reason: String.t(), usage: map()}}
  @type error_result ::
          {:error, :not_configured}
          | {:error, {:transient, non_neg_integer() | atom(), any()}}
          | {:error, {:http_error, non_neg_integer(), any()}}
          | {:error, {:unexpected_status, non_neg_integer(), any()}}
          | {:error, any()}

  @doc "Returns `:ok` when an API key is configured, `:not_configured` otherwise."
  @spec status() :: :ok | :not_configured
  def status, do: status_from_key(fetch_api_key())

  @doc """
  Issues a single completion request against Anthropic's Messages API.

  The `prompt` argument is either a plain string (wrapped as a single
  user message) or a list of `%{role: ..., content: ...}` turns.
  """
  @spec complete(prompt(), opts()) :: ok_result() | error_result()
  def complete(prompt, opts \\ []) do
    dispatch(prompt, opts, fetch_api_key())
  end

  # --- dispatch --------------------------------------------------------------

  defp dispatch(_prompt, _opts, nil), do: {:error, :not_configured}
  defp dispatch(_prompt, _opts, ""), do: {:error, :not_configured}

  defp dispatch(prompt, opts, api_key) do
    body = build_request_body(prompt, opts)

    api_key
    |> build_request()
    |> Req.post(json: body)
    |> classify()
  end

  # --- request construction --------------------------------------------------

  defp build_request(api_key) do
    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", anthropic_version()}
    ]

    base = [
      url: "/v1/messages",
      base_url: base_url(),
      headers: headers,
      receive_timeout: 60_000,
      retry: false
    ]

    Req.new(base ++ extra_req_options())
  end

  defp build_request_body(prompt, opts) do
    %{
      model: Keyword.get(opts, :model, default_model()),
      max_tokens: Keyword.get(opts, :max_tokens, default_max_tokens()),
      messages: normalize_messages(prompt)
    }
    |> maybe_put(:system, Keyword.get(opts, :system))
    |> maybe_put(:temperature, Keyword.get(opts, :temperature))
  end

  defp normalize_messages(prompt) when is_binary(prompt),
    do: [%{role: "user", content: prompt}]

  defp normalize_messages(messages) when is_list(messages),
    do: Enum.map(messages, &normalize_message/1)

  defp normalize_message(%{role: role, content: content}) when is_binary(role),
    do: %{role: role, content: content}

  defp normalize_message(%{"role" => role, "content" => content}),
    do: %{role: role, content: content}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # --- response classification ----------------------------------------------

  defp classify({:ok, %Req.Response{status: 200, body: body}}), do: parse_success(body)

  defp classify({:ok, %Req.Response{status: status, body: body}}) when status in 201..299 do
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

  defp parse_success(%{"content" => content} = body) do
    text = extract_first_text(content)

    {:ok,
     %{
       text: text,
       model: body["model"],
       stop_reason: body["stop_reason"],
       usage: body["usage"] || %{}
     }}
  end

  defp parse_success(body) do
    {:error, {:unexpected_body, body}}
  end

  defp extract_first_text(content) when is_list(content) do
    Enum.find_value(content, "", fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      _ -> nil
    end)
  end

  defp extract_first_text(_), do: ""

  # --- config ----------------------------------------------------------------

  defp status_from_key(nil), do: :not_configured
  defp status_from_key(""), do: :not_configured
  defp status_from_key(_key), do: :ok

  defp base_url, do: config(:base_url) || @default_base_url
  defp fetch_api_key, do: config(:api_key)
  defp default_model, do: config(:default_model) || @default_model
  defp default_max_tokens, do: config(:max_tokens) || @default_max_tokens
  defp anthropic_version, do: config(:anthropic_version) || @default_anthropic_version
  defp extra_req_options, do: config(:req_options) || []

  defp config(key) do
    @config_app
    |> Application.get_env(@config_key, [])
    |> Keyword.get(@provider, [])
    |> Keyword.get(key)
  end
end
