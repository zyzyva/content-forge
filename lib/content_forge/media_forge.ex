defmodule ContentForge.MediaForge do
  @moduledoc """
  HTTP client for the Media Forge media processing service.

  Every Content Forge caller that needs Media Forge goes through this module.
  It centralises the base URL, the shared-secret authentication header, the
  transient-versus-permanent error classification, and test stubbing. Nothing
  else in the codebase should build raw HTTP requests against Media Forge URLs.

  ## Configuration

      config :content_forge, :media_forge,
        base_url: "http://192.168.1.37:5001",
        secret: System.get_env("MEDIA_FORGE_SECRET")

  The base URL defaults to the LAN dev instance when omitted. The secret is
  required; when it is missing, `status/0` reports `:not_configured` and every
  call function returns `{:error, :not_configured}` immediately without issuing
  any HTTP request.

  ## Return shapes

  On success, each call returns `{:ok, body}` where `body` is the decoded JSON
  response from Media Forge. Callers are responsible for reading the job
  identifier (e.g. `body["jobId"]`) from the returned map.

  On failure, the error tuple is classified:

    * `{:error, :not_configured}` -secret not configured
    * `{:error, {:transient, status, body}}` -5xx response from Media Forge
    * `{:error, {:transient, :timeout, reason}}` -HTTP timeout
    * `{:error, {:transient, :network, reason}}` -connection refused, DNS
      failure, or other network-layer error
    * `{:error, {:http_error, status, body}}` -4xx response, do not retry
      without changing the input
    * `{:error, reason}` -unexpected condition, inspect `reason` for context

  Transient errors may be retried by the caller's Oban backoff policy.
  Permanent errors must not be retried without changing the input.
  """

  @config_app :content_forge
  @config_key :media_forge

  @type ok_result :: {:ok, map()}
  @type err_not_configured :: {:error, :not_configured}
  @type err_transient :: {:error, {:transient, non_neg_integer() | atom(), any()}}
  @type err_permanent :: {:error, {:http_error, non_neg_integer(), any()}}
  @type err_other :: {:error, any()}
  @type result ::
          ok_result() | err_not_configured() | err_transient() | err_permanent() | err_other()

  @doc "Returns `:ok` when a secret is configured, `:not_configured` otherwise."
  @spec status() :: :ok | :not_configured
  def status, do: status_from_secret(fetch_secret())

  @doc "Probes video metadata by posting to `/api/v1/video/probe`."
  @spec probe(map()) :: result()
  def probe(params), do: do_post("/api/v1/video/probe", params)

  @doc "Enqueues a video normalization job."
  @spec enqueue_video_normalize(map()) :: result()
  def enqueue_video_normalize(params), do: do_post("/api/v1/video/normalize", params)

  @doc "Enqueues a video render job."
  @spec enqueue_video_render(map()) :: result()
  def enqueue_video_render(params), do: do_post("/api/v1/video/render", params)

  @doc "Enqueues a video trim job."
  @spec enqueue_video_trim(map()) :: result()
  def enqueue_video_trim(params), do: do_post("/api/v1/video/trim", params)

  @doc "Enqueues a batch video job."
  @spec enqueue_video_batch(map()) :: result()
  def enqueue_video_batch(params), do: do_post("/api/v1/video/batch", params)

  @doc "Enqueues an image processing job."
  @spec enqueue_image_process(map()) :: result()
  def enqueue_image_process(params), do: do_post("/api/v1/image/process", params)

  @doc "Enqueues an image render job."
  @spec enqueue_image_render(map()) :: result()
  def enqueue_image_render(params), do: do_post("/api/v1/image/render", params)

  @doc "Enqueues a batch image job."
  @spec enqueue_image_batch(map()) :: result()
  def enqueue_image_batch(params), do: do_post("/api/v1/image/batch", params)

  @doc "Requests AI image generation. The returned map may be synchronous or carry a job id."
  @spec generate_images(map()) :: result()
  def generate_images(params), do: do_post("/api/v1/generation/images", params)

  @doc "Requests head-to-head comparison of generated images."
  @spec compare_generations(map()) :: result()
  def compare_generations(params), do: do_post("/api/v1/generation/compare", params)

  @doc "Fetches the status of a Media Forge job."
  @spec get_job(String.t()) :: result()
  def get_job(id), do: do_get("/api/v1/jobs/" <> id)

  @doc "Requests cancellation of a Media Forge job."
  @spec cancel_job(String.t()) :: result()
  def cancel_job(id), do: do_post("/api/v1/jobs/" <> id <> "/cancel", %{})

  # --- Internals -----------------------------------------------------------

  defp do_post(path, params), do: dispatch(:post, path, params)
  defp do_get(path), do: dispatch(:get, path, nil)

  defp dispatch(method, path, body), do: dispatch_with_secret(method, path, body, fetch_secret())

  defp dispatch_with_secret(_method, _path, _body, nil), do: {:error, :not_configured}
  defp dispatch_with_secret(_method, _path, _body, ""), do: {:error, :not_configured}

  defp dispatch_with_secret(method, path, body, secret) do
    method
    |> request(path, body, secret)
    |> classify()
  end

  defp request(:get, path, _body, secret) do
    Req.get(build_request(path, secret))
  end

  defp request(:post, path, body, secret) do
    Req.post(build_request(path, secret), json: body)
  end

  defp build_request(path, secret) do
    base = [
      url: path,
      base_url: base_url(),
      headers: [{"x-mediaforge-secret", secret}],
      receive_timeout: 30_000,
      retry: false
    ]

    Req.new(base ++ extra_req_options())
  end

  # --- Response classification --------------------------------------------

  defp classify({:ok, %Req.Response{status: status, body: body}}) when status in 200..299 do
    {:ok, body}
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

  # --- Config --------------------------------------------------------------

  defp status_from_secret(nil), do: :not_configured
  defp status_from_secret(""), do: :not_configured
  defp status_from_secret(_secret), do: :ok

  defp base_url, do: config(:base_url) || "http://192.168.1.37:5001"
  defp fetch_secret, do: config(:secret)
  defp extra_req_options, do: config(:req_options) || []

  defp config(key) do
    @config_app
    |> Application.get_env(@config_key, [])
    |> Keyword.get(key)
  end
end
