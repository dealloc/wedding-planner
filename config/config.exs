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

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
