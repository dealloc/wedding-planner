# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :wedding_planner,
  ecto_repos: [WeddingPlanner.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :wedding_planner, WeddingPlannerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: WeddingPlannerWeb.ErrorHTML, json: WeddingPlannerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: WeddingPlanner.PubSub,
  live_view: [signing_salt: "mu9JMfIB"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  wedding_planner: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  wedding_planner: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Dates and times — NFR-20 to NFR-23.
#
# NFR-22 needs UTC moments converted to a real IANA zone, which Elixir cannot do with its
# built-in UTC-only database. `tz` compiles the IANA data at build time and keeps its
# runtime updater off by default, so builds stay hermetic and the app makes no outbound
# HTTP calls — unlike `tzdata`, which fetches updates over HTTP at runtime (DR-19).
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# NFR-22: the app-wide fallback used when the browser reports no usable zone.
config :wedding_planner, :default_time_zone, "Europe/Brussels"

# Money — NFR-10 to NFR-15. EUR is the single app currency (NFR-15); the currency is
# still stored with every amount. Exchange rates are never needed here, and ex_money 6
# deprecates auto-starting the retriever.
config :ex_money,
  auto_start_exchange_rate_service: false,
  exchange_rates_retrieve_every: :never

# NFR-11 — no CLDR backend module and no :default_cldr_backend. ex_money 6 resolves
# locales at runtime through `localize`.
#
# The locale is load-bearing twice over (DR-17): it fixes how every money figure renders
# (nl-BE gives "€ 11.726,00") and it decides the currency a currency-less Money.parse/1
# derives. :en would silently derive USD; nl-BE derives EUR.
#
# :otp_app anchors the locale cache under this app's priv/, so mix, mix test and a
# release all resolve the same path.
config :localize,
  otp_app: :wedding_planner,
  default_locale: :"nl-BE",
  supported_locales: [:"nl-BE"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Parameter keys are matched by substring, so "token" also covers `setup_token` —
# AUTH-03 / D-33 forbid the bootstrap token from ever reaching a log. LiveView's
# event logging goes through the same filter.
config :phoenix, :filter_parameters, ["password", "token"]

# EVT-05 / XC-40 — what else references an event, shown in its delete confirmation.
# Tasks (T1) are the first reference type (DR-26, amending DR-5's split); later slices
# (G3 invitations, C2 offer lines) append their own providers here.
config :wedding_planner,
  event_reference_providers: [
    &WeddingPlanner.Tasks.event_deadline_reference/1,
    &WeddingPlanner.Tasks.event_link_reference/1,
    &WeddingPlanner.Invitations.event_invitation_reference/1,
    &WeddingPlanner.Invitations.event_opt_out_reference/1
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
