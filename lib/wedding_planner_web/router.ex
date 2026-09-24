defmodule WeddingPlannerWeb.Router do
  use WeddingPlannerWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {WeddingPlannerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # AUTH-01: guards both plain controller routes and the authenticated `live_session`
  # below. See `WeddingPlannerWeb.UserAuth`'s moduledoc for why the plug (not just the
  # `on_mount` hook) is what makes `return_to` work.
  pipeline :require_authenticated_user do
    plug WeddingPlannerWeb.UserAuth, :require_authenticated_user
  end

  scope "/", WeddingPlannerWeb do
    pipe_through :browser

    # AUTH-01 leaves no public home page — `/` just forwards to the authenticated
    # `/home`, which redirects on to `/login` itself if the visitor isn't signed in.
    get "/", RootController, :redirect_home

    # AUTH-01's three public routes: login, the one-time setup page, and the enrollment
    # page reached via a valid link (task 16).
    live_session :public do
      live "/login", Live.LoginLive
      live "/setup", Live.SetupLive
      live "/enroll/:token", Live.EnrollmentLive
    end

    # The bridge `WeddingPlannerWeb.Live.LoginLive` submits to (sets the session cookie)
    # and its sign-out counterpart (clears it) — see `WeddingPlannerWeb.SessionController`.
    # Deliberately public: `create/2` re-verifies the session token itself, and `delete/2`
    # is a no-op for a visitor who isn't signed in.
    post "/session", SessionController, :create
    delete "/session", SessionController, :delete

    scope "/" do
      pipe_through :require_authenticated_user

      get "/references/:id/file", ReferenceFileController, :show
      get "/references/:id/download", ReferenceFileController, :download

      live_session :authenticated,
        on_mount: [{WeddingPlannerWeb.UserAuth, :require_authenticated}] do
        live "/home", HomeLive
        live "/people", Live.PeopleLive
        live "/people/:id", Live.PersonLive
        live "/invitations", Live.InvitationsLive
        live "/headcount", Live.HeadcountLive
        live "/events", Live.EventsLive, :index
        live "/events/new", Live.EventsLive, :new
        live "/events/:id/edit", Live.EventsLive, :edit
        live "/tasks", Live.TasksLive
        live "/categories", Live.CategoriesLive, :index
        live "/categories/new", Live.CategoriesLive, :new
        live "/categories/:id/edit", Live.CategoriesLive, :edit
        live "/categories/:id", Live.CategoryLive
        live "/offers/:id", Live.OfferLive
        live "/invoices", Live.InvoicesLive
        live "/invoices/:id", Live.InvoiceLive
        live "/activity", Live.ActivityLogLive
        live "/enrollment-links", Live.EnrollmentLinksLive
        live "/devices", Live.DevicesLive
        live "/settings", Live.SettingsLive
      end
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", WeddingPlannerWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:wedding_planner, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: WeddingPlannerWeb.Telemetry
    end
  end
end
