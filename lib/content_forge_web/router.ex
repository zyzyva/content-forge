defmodule ContentForgeWeb.Router do
  use ContentForgeWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ContentForgeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_auth do
    plug ContentForgeWeb.Plugs.ApiAuth
  end

  scope "/", ContentForgeWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/api/v1", ContentForgeWeb do
    pipe_through :api
    pipe_through :api_auth

    resources "/products", ProductController, only: [:index, :show, :create, :update, :delete]

    scope "/products/:product_id" do
      resources "/competitors", CompetitorController,
        only: [:index, :show, :create, :update, :delete]
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", ContentForgeWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:content_forge, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ContentForgeWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
