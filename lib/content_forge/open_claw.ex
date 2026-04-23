defmodule ContentForge.OpenClaw do
  @moduledoc """
  HTTP client for the OpenClaw bulk-generation service.

  OpenClaw is the ecosystem's fast, cheap, high-volume first-draft generator:
  it produces the N variants per platform and angle that the smarter LLMs
  (Anthropic, Gemini) then rank and critique. Every Content Forge caller
  that needs a bulk-variant batch goes through this module. Nothing else
  should build raw HTTP requests against OpenClaw URLs.

  ## Configuration

      config :content_forge, :open_claw,
        base_url: System.get_env("OPENCLAW_BASE_URL"),
        api_key: System.get_env("OPENCLAW_API_KEY"),
        default_timeout: 60_000

  Both `:base_url` and `:api_key` are required. When either is missing
  `status/0` reports `:not_configured` and every call returns
  `{:error, :not_configured}` with zero HTTP I/O so callers can downgrade
  gracefully rather than fabricating drafts.

  ## Authentication

  The client attaches `Authorization: Bearer <api_key>` on every
  request. This is the target shape for OpenClaw's bulk endpoint as of
  the 11.2 (infra) handoff; if the running instance uses a different
  header convention (for example `x-openclaw-key`), switching is a
  one-call-site fix inside `build_request/1` and not a client rewrite.

  ## Endpoint and request shape

  The client POSTs to `/api/v1/generate` with the following JSON body:

      {
        "content_type": "post" | "blog" | "video_script",
        "platform": "twitter" | "linkedin" | "reddit" | ...  (post only),
        "angle": "educational" | "humor" | ...               (optional),
        "count": N,
        "brief": "<content brief markdown>",
        "product": { "name": ..., "voice_profile": ..., "site_summary": ... },
        "performance_insights": { ... }                       (optional)
      }

  The success response is parsed into
  `{:ok, %{variants: [%{text, angle, model}, ...], model, usage}}`.
  Callers iterate `variants` to persist Draft records.

  ## Error classification

    * `{:error, :not_configured}` - base URL or API key not configured
    * `{:error, {:transient, status, body}}` - 5xx or 429
    * `{:error, {:transient, :timeout, reason}}` - HTTP timeout
    * `{:error, {:transient, :network, reason}}` - network-layer error
    * `{:error, {:http_error, status, body}}` - other 4xx
    * `{:error, {:unexpected_status, status, body}}` - 3xx
    * `{:error, reason}` - anything else
  """

  require Logger

  @config_app :content_forge
  @config_key :open_claw

  @default_timeout 60_000
  @endpoint "/api/v1/generate"

  @type content_type :: :post | :blog | :video_script | String.t()
  @type request :: %{
          required(:content_type) => content_type(),
          required(:count) => pos_integer(),
          optional(:platform) => String.t(),
          optional(:angle) => String.t(),
          optional(:brief) => String.t(),
          optional(:product) => map(),
          optional(:performance_insights) => map()
        }
  @type variant :: %{text: String.t(), angle: String.t() | nil, model: String.t() | nil}
  @type ok_result :: {:ok, %{variants: [variant()], model: String.t() | nil, usage: map()}}
  @type error_result ::
          {:error, :not_configured}
          | {:error, {:transient, non_neg_integer() | atom(), any()}}
          | {:error, {:http_error, non_neg_integer(), any()}}
          | {:error, {:unexpected_status, non_neg_integer(), any()}}
          | {:error, any()}

  @doc "Returns `:ok` when base URL and API key are configured, `:not_configured` otherwise."
  @spec status() :: :ok | :not_configured
  def status, do: status_from_config(fetch_base_url(), fetch_api_key())

  @doc """
  Generates a batch of content variants.

  The `request` map identifies the content kind, the target platform (for
  social posts), the angle, the desired variant count, and the contextual
  payload (brief + product). See the moduledoc for the full schema.
  """
  @spec generate_variants(request(), keyword()) :: ok_result() | error_result()
  def generate_variants(request, opts \\ []) do
    dispatch(request, opts, fetch_base_url(), fetch_api_key())
  end

  # --- dispatch -------------------------------------------------------------

  defp dispatch(_request, _opts, nil, _api_key), do: {:error, :not_configured}
  defp dispatch(_request, _opts, _base_url, nil), do: {:error, :not_configured}
  defp dispatch(_request, _opts, _base_url, ""), do: {:error, :not_configured}
  defp dispatch(_request, _opts, "", _api_key), do: {:error, :not_configured}

  defp dispatch(request, _opts, _base_url, api_key) do
    body = build_request_body(request)

    api_key
    |> build_request()
    |> Req.post(json: body)
    |> classify()
  end

  # --- request construction -------------------------------------------------

  defp build_request(api_key) do
    headers = [{"authorization", "Bearer #{api_key}"}]

    base = [
      url: @endpoint,
      base_url: base_url(),
      headers: headers,
      receive_timeout: default_timeout(),
      retry: false
    ]

    Req.new(base ++ extra_req_options())
  end

  defp build_request_body(request) do
    %{
      content_type: to_string(request[:content_type] || request["content_type"]),
      count: request[:count] || request["count"]
    }
    |> maybe_put(:platform, request[:platform] || request["platform"])
    |> maybe_put(:angle, request[:angle] || request["angle"])
    |> maybe_put(:brief, request[:brief] || request["brief"])
    |> maybe_put(:product, request[:product] || request["product"])
    |> maybe_put(
      :performance_insights,
      request[:performance_insights] || request["performance_insights"]
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # --- response classification ---------------------------------------------

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

  defp parse_success(%{"variants" => variants} = body) when is_list(variants) do
    {:ok,
     %{
       variants: Enum.map(variants, &parse_variant/1),
       model: body["model"],
       usage: body["usage"] || %{}
     }}
  end

  defp parse_success(body), do: {:error, {:unexpected_body, body}}

  defp parse_variant(%{"text" => text} = v) do
    %{text: text, angle: v["angle"], model: v["model"]}
  end

  defp parse_variant(v), do: %{text: nil, angle: v["angle"], model: v["model"], raw: v}

  # --- config ---------------------------------------------------------------

  defp status_from_config(nil, _), do: :not_configured
  defp status_from_config("", _), do: :not_configured
  defp status_from_config(_, nil), do: :not_configured
  defp status_from_config(_, ""), do: :not_configured
  defp status_from_config(_base, _key), do: :ok

  defp base_url, do: fetch_base_url()
  defp fetch_base_url, do: config(:base_url)
  defp fetch_api_key, do: config(:api_key)
  defp default_timeout, do: config(:default_timeout) || @default_timeout
  defp extra_req_options, do: config(:req_options) || []

  defp config(key) do
    @config_app
    |> Application.get_env(@config_key, [])
    |> Keyword.get(key)
  end
end
