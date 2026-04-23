defmodule ContentForge.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias ContentForgeWeb.Plugs.QueryCountHeader

  @impl true
  def start(_type, _args) do
    children = [
      ContentForgeWeb.Telemetry,
      ContentForge.Repo,
      {DNSCluster, query: Application.get_env(:content_forge, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ContentForge.PubSub},
      {Oban, Application.get_env(:content_forge, Oban)},
      # Start a worker by calling: ContentForge.Worker.start_link(arg)
      # {ContentForge.Worker, arg},
      # Start to serve requests, typically the last entry
      ContentForgeWeb.Endpoint
    ]

    QueryCountHeader.attach_telemetry()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ContentForge.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ContentForgeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
