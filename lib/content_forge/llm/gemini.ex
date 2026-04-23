defmodule ContentForge.LLM.Gemini do
  @moduledoc """
  HTTP client for Google's Gemini `generateContent` endpoint.

  Sibling to `ContentForge.LLM.Anthropic`. The public `complete/2` function
  is shape-compatible with Anthropic's so both providers are
  substitutable at the call site: same prompt argument (string or list of
  role/content turns), same options keyword list, and the same
  `{:ok, %{text, model, stop_reason, usage}}` success shape.

  ## Configuration

      config :content_forge, :llm,
        gemini: [
          base_url: "https://generativelanguage.googleapis.com",
          api_key: System.get_env("GEMINI_API_KEY"),
          default_model: "gemini-2.5-flash",
          max_tokens: 4096
        ]

  The API key is required; when it is missing, `status/0` reports
  `:not_configured` and every call returns `{:error, :not_configured}`
  immediately with zero HTTP I/O.

  ## Return shapes

  Error classification matches `ContentForge.LLM.Anthropic` and
  `ContentForge.MediaForge`:

    * `{:error, :not_configured}` -api key is unset
    * `{:error, {:transient, status, body}}` -5xx or 429 response
    * `{:error, {:transient, :timeout, reason}}` -HTTP timeout
    * `{:error, {:transient, :network, reason}}` -network-layer error
    * `{:error, {:http_error, status, body}}` -other 4xx
    * `{:error, {:unexpected_status, status, body}}` -3xx response
    * `{:error, reason}` -anything else
  """

  require Logger

  @config_app :content_forge
  @config_key :llm
  @provider :gemini

  @default_base_url "https://generativelanguage.googleapis.com"
  @default_model "gemini-2.5-flash"
  @default_max_tokens 4096

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
  Issues a single completion request against Gemini's generateContent
  endpoint.

  `prompt` is either a plain string (wrapped as a single user turn) or a
  list of `%{role: "user" | "assistant", content: ...}` turns. The
  `"assistant"` role is translated to Gemini's `"model"` role internally.
  """
  @spec complete(prompt(), opts()) :: ok_result() | error_result()
  def complete(prompt, opts \\ []) do
    dispatch(prompt, opts, fetch_api_key())
  end

  # --- dispatch --------------------------------------------------------------

  defp dispatch(_prompt, _opts, nil), do: {:error, :not_configured}
  defp dispatch(_prompt, _opts, ""), do: {:error, :not_configured}

  defp dispatch(prompt, opts, api_key) do
    model = Keyword.get(opts, :model, default_model())
    body = build_request_body(prompt, opts)

    model
    |> build_request(api_key)
    |> Req.post(json: body)
    |> classify(model)
  end

  # --- request construction --------------------------------------------------

  defp build_request(model, api_key) do
    headers = [{"x-goog-api-key", api_key}]

    base = [
      url: "/v1beta/models/#{model}:generateContent",
      base_url: base_url(),
      headers: headers,
      receive_timeout: 60_000,
      retry: false
    ]

    Req.new(base ++ extra_req_options())
  end

  defp build_request_body(prompt, opts) do
    %{
      contents: normalize_contents(prompt),
      generationConfig: generation_config(opts)
    }
    |> maybe_put(:systemInstruction, system_instruction(Keyword.get(opts, :system)))
  end

  defp normalize_contents(prompt) when is_binary(prompt),
    do: [%{role: "user", parts: [%{text: prompt}]}]

  defp normalize_contents(messages) when is_list(messages),
    do: Enum.map(messages, &normalize_message/1)

  defp normalize_message(%{role: role, content: content}) when is_binary(role),
    do: %{role: gemini_role(role), parts: [%{text: content}]}

  defp normalize_message(%{"role" => role, "content" => content}),
    do: %{role: gemini_role(role), parts: [%{text: content}]}

  defp gemini_role("assistant"), do: "model"
  defp gemini_role(role), do: role

  defp generation_config(opts) do
    %{maxOutputTokens: Keyword.get(opts, :max_tokens, default_max_tokens())}
    |> maybe_put(:temperature, Keyword.get(opts, :temperature))
  end

  defp system_instruction(nil), do: nil
  defp system_instruction(""), do: nil
  defp system_instruction(text), do: %{parts: [%{text: text}]}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # --- response classification ----------------------------------------------

  defp classify({:ok, %Req.Response{status: status, body: body}}, model)
       when status in 200..299 do
    parse_success(body, model)
  end

  defp classify({:ok, %Req.Response{status: status, body: body}}, _model)
       when status in 300..399 do
    {:error, {:unexpected_status, status, body}}
  end

  defp classify({:ok, %Req.Response{status: 429, body: body}}, _model) do
    {:error, {:transient, 429, body}}
  end

  defp classify({:ok, %Req.Response{status: status, body: body}}, _model)
       when status in 400..499 do
    {:error, {:http_error, status, body}}
  end

  defp classify({:ok, %Req.Response{status: status, body: body}}, _model)
       when status >= 500 do
    {:error, {:transient, status, body}}
  end

  defp classify({:error, %Req.TransportError{reason: :timeout} = err}, _model) do
    {:error, {:transient, :timeout, err.reason}}
  end

  defp classify({:error, %Req.TransportError{reason: reason}}, _model)
       when reason in [:econnrefused, :nxdomain, :ehostunreach, :enetunreach, :closed] do
    {:error, {:transient, :network, reason}}
  end

  defp classify({:error, reason}, _model), do: {:error, reason}

  defp parse_success(%{"candidates" => [first | _]} = body, model) do
    text =
      first
      |> Map.get("content", %{})
      |> Map.get("parts", [])
      |> extract_first_text()

    {:ok,
     %{
       text: text,
       model: body["modelVersion"] || model,
       stop_reason: first["finishReason"],
       usage: body["usageMetadata"] || %{}
     }}
  end

  defp parse_success(body, _model), do: {:error, {:unexpected_body, body}}

  defp extract_first_text(parts) when is_list(parts) do
    Enum.find_value(parts, "", fn
      %{"text" => text} when is_binary(text) -> text
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
  defp extra_req_options, do: config(:req_options) || []

  defp config(key) do
    @config_app
    |> Application.get_env(@config_key, [])
    |> Keyword.get(@provider, [])
    |> Keyword.get(key)
  end
end
