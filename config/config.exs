# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :content_forge,
  ecto_repos: [ContentForge.Repo],
  generators: [timestamp_type: :utc_datetime]

# Phase 12.4 publish gate: blog drafts with seo_score below this
# threshold (or with research_status=lost_data_point) cannot be
# moved to "approved" via the normal approve action; the override
# path records the reason + state snapshot at approval.
config :content_forge, :seo, publish_threshold: 18

# Configure the endpoint
config :content_forge, ContentForgeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ContentForgeWeb.ErrorHTML, json: ContentForgeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ContentForge.PubSub,
  live_view: [signing_salt: "vzlwZ4fU"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :content_forge, ContentForge.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  content_forge: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  content_forge: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Configure Oban
config :content_forge, Oban,
  repo: ContentForge.Repo,
  queues: [
    default: 10,
    events: 50,
    content_generation: 10,
    ingestion: 5,
    competitor: 5
  ],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       # Hourly reminder sweep: iterates products with enabled
       # ReminderConfig and enqueues a ReminderDispatcher per eligible
       # phone. Cadence/pause/quiet-hours gates live in the worker.
       {"0 * * * *", ContentForge.Jobs.ReminderScheduler}
     ]}
  ]

# Default LLM provider configuration. The API key is sourced from an
# environment variable at runtime (see config/runtime.exs); the defaults
# below only cover the model name, token budget, and base URL so no
# caller has to hardcode them.
config :content_forge, :llm,
  anthropic: [
    base_url: "https://api.anthropic.com",
    default_model: "claude-sonnet-4-6",
    max_tokens: 4096
  ],
  gemini: [
    base_url: "https://generativelanguage.googleapis.com",
    default_model: "gemini-2.5-flash",
    max_tokens: 4096
  ]

# Register MIME types that are not in the default Mime table but are
# used by the product-asset upload allow-list. This must stay in sync
# with the @upload_accept_mimes attribute in
# ContentForgeWeb.Live.Dashboard.Products.DetailLive.
config :mime, :types, %{
  "image/heic" => ["heic"],
  "video/x-m4v" => ["m4v"]
}

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
