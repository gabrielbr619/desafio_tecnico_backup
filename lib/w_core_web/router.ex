defmodule WCoreWeb.Router do
  use WCoreWeb, :router

  import WCoreWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {WCoreWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug WCoreWeb.ApiAuthPlug
  end

  scope "/", WCoreWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/health", HealthController, :index
  end

  scope "/api/v1", WCoreWeb do
    pipe_through :api

    post "/heartbeat", HeartbeatController, :create
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:w_core, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    pipeline :mailbox_styles do
      plug WCoreWeb.Plugs.MailboxStyleInjector
    end

    scope "/dev" do
      pipe_through [:browser, :mailbox_styles]

      live_dashboard "/dashboard", metrics: WCoreWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", WCoreWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{WCoreWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
      live "/dashboard", DashboardLive, :index
      live "/nodes/:id", NodeLive, :show
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", WCoreWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{WCoreWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
