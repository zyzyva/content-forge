defmodule ContentForge.Test.E2EStubs do
  @moduledoc """
  Shared Req.Test stub helpers for end-to-end pipeline tests.

  Each helper sets up a single external-client namespace in
  `Application.env` + installs a `Req.Test` plug so the associated
  `ContentForge.*` client module routes through an in-process mock
  instead of the real network. Tests opt into which stubs they need.

  Example:

      setup do
        ContentForge.Test.E2EStubs.setup_llm_stubs()
        :ok
      end

      test "pipeline" do
        ContentForge.Test.E2EStubs.stub_anthropic_text(
          "my brief text"
        )
        # ... exercise the worker that calls Anthropic ...
      end

  The stubs are scoped to the current test process via
  `Req.Test.stub/2`, so concurrent tests do not bleed into each
  other's mocks.

  ## Supported stubs

    * `setup_llm_stubs/0` - installs Anthropic + Gemini config with
      `Req.Test` plugs (wiring only; `stub_anthropic_*` /
      `stub_gemini_*` set the actual responses).
    * `setup_media_forge_stubs/0` - Media Forge client config + plug.
    * `setup_twilio_stubs/0` - Twilio client config + plug.
    * `setup_open_claw_stubs/0` - OpenClaw client config + plug.
    * `setup_apify_stubs/0` - Apify client config + plug.

  ## Limitations

  Platform publisher clients (`ContentForge.Publishing.Twitter` /
  `ContentForge.Publishing.LinkedIn` / etc.) currently issue raw
  `Req.get` / `Req.post` calls without a `req_options` seam, so
  they can't be plug-stubbed through config. E2E tests that need to
  prove a published state should write the `PublishedPost` row
  directly (paired with `draft.status = "published"`) until those
  clients are refactored. Documented in BUILDPLAN 15.3.2+ territory.
  """

  @llm_config_key :llm
  @media_forge_config_key :media_forge
  @twilio_config_key :twilio
  @open_claw_config_key :open_claw
  @apify_config_key :apify

  @anthropic_stub ContentForge.LLM.Anthropic
  @gemini_stub ContentForge.LLM.Gemini
  @media_forge_stub ContentForge.MediaForge
  @twilio_stub ContentForge.Twilio
  @open_claw_stub ContentForge.OpenClaw
  @apify_stub ContentForge.CompetitorScraper.ApifyAdapter

  # --- LLM (Anthropic + Gemini) -------------------------------------------

  @doc "Configures both LLM providers and installs Req.Test plugs."
  def setup_llm_stubs do
    original = Application.get_env(:content_forge, @llm_config_key, [])

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:content_forge, @llm_config_key, original)
    end)

    Application.put_env(:content_forge, @llm_config_key,
      anthropic: [
        base_url: "http://anthropic.test",
        api_key: "sk-test-anthropic",
        default_model: "claude-sonnet-4-6",
        max_tokens: 1024,
        req_options: [plug: {Req.Test, @anthropic_stub}]
      ],
      gemini: [
        base_url: "http://gemini.test",
        api_key: "gk-test-gemini",
        default_model: "gemini-2.5-flash",
        max_tokens: 1024,
        req_options: [plug: {Req.Test, @gemini_stub}]
      ]
    )

    :ok
  end

  @doc "Stubs Anthropic to return a plain-text completion for any call."
  def stub_anthropic_text(text) do
    Req.Test.stub(@anthropic_stub, fn conn ->
      Req.Test.json(conn, %{
        "id" => "msg_01",
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => text}],
        "model" => "claude-sonnet-4-6",
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 12, "output_tokens" => 34}
      })
    end)
  end

  @doc "Stubs Gemini to return a plain-text completion for any call."
  def stub_gemini_text(text) do
    Req.Test.stub(@gemini_stub, fn conn ->
      Req.Test.json(conn, %{
        "candidates" => [
          %{
            "content" => %{"parts" => [%{"text" => text}], "role" => "model"},
            "finishReason" => "STOP"
          }
        ],
        "usageMetadata" => %{"totalTokenCount" => 42},
        "modelVersion" => "gemini-2.5-flash"
      })
    end)
  end

  # --- Media Forge --------------------------------------------------------

  @doc "Installs Media Forge config + Req.Test plug."
  def setup_media_forge_stubs do
    original = Application.get_env(:content_forge, @media_forge_config_key, [])

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:content_forge, @media_forge_config_key, original)
    end)

    Application.put_env(:content_forge, @media_forge_config_key,
      base_url: "http://media-forge.test",
      secret: "test-secret",
      webhook_secret: "test-secret",
      req_options: [plug: {Req.Test, @media_forge_stub}]
    )

    :ok
  end

  # --- Twilio -------------------------------------------------------------

  @doc "Installs Twilio config + Req.Test plug."
  def setup_twilio_stubs do
    original = Application.get_env(:content_forge, @twilio_config_key, [])

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:content_forge, @twilio_config_key, original)
    end)

    Application.put_env(:content_forge, @twilio_config_key,
      base_url: "http://twilio.test",
      account_sid: "AC_test",
      auth_token: "test-auth-token",
      from_number: "+15557654321",
      default_messaging_service_sid: nil,
      req_options: [plug: {Req.Test, @twilio_stub}]
    )

    :ok
  end

  # --- OpenClaw -----------------------------------------------------------

  @doc "Installs OpenClaw config + Req.Test plug."
  def setup_open_claw_stubs do
    original = Application.get_env(:content_forge, @open_claw_config_key, [])

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:content_forge, @open_claw_config_key, original)
    end)

    Application.put_env(:content_forge, @open_claw_config_key,
      base_url: "http://openclaw.test",
      api_key: "oc-test",
      default_timeout: 10_000,
      req_options: [plug: {Req.Test, @open_claw_stub}]
    )

    :ok
  end

  # --- Apify --------------------------------------------------------------

  @doc "Installs Apify config + Req.Test plug."
  def setup_apify_stubs do
    original = Application.get_env(:content_forge, @apify_config_key, [])

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:content_forge, @apify_config_key, original)
    end)

    Application.put_env(:content_forge, @apify_config_key,
      base_url: "http://apify.test",
      token: "apify-test",
      actors: %{},
      poll_interval_ms: 10,
      poll_max_attempts: 3,
      req_options: [plug: {Req.Test, @apify_stub}]
    )

    :ok
  end
end
