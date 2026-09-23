import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/wedding_planner start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :wedding_planner, WeddingPlannerWeb.Endpoint, server: true
end

config :wedding_planner, WeddingPlannerWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :wedding_planner, WeddingPlannerWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/wedding_planner_web/router\.ex$"E,
        ~r"lib/wedding_planner_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /var/wedding_planner/wedding_planner.db
      """

  config :wedding_planner, WeddingPlanner.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # NFR-04/XC-23 — the persistent volume holds the database above AND the uploads
  # directory below; both paths come from the environment so they can point at the
  # mounted volume (see fly.toml) rather than the ephemeral container filesystem.
  # No module reads this yet (uploads are a later slice), but the path MUST be
  # settled now so the volume layout doesn't have to change under a later deploy.
  uploads_path =
    System.get_env("UPLOADS_PATH") ||
      raise """
      environment variable UPLOADS_PATH is missing.
      For example: /var/wedding_planner/uploads
      """

  config :wedding_planner, :uploads_dir, uploads_path

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # NFR-05 — HTTPS only. The scheme and port below are fixed, not read from the
  # environment: Fly always terminates TLS at its edge and presents the app on 443,
  # and NFR-05 forbids anything else. PHX_HOST is the one thing that genuinely
  # varies per deploy, so it is the only piece read from the environment — and it
  # is required, not defaulted, because a silent fallback here would silently mismatch
  # the WebAuthn origin below and break every passkey (see AUTH-02 origin note).
  scheme = "https"
  port = 443

  host =
    System.get_env("PHX_HOST") ||
      raise """
      environment variable PHX_HOST is missing.
      For example: wedding.example.com

      This becomes part of the WebAuthn origin (see below) as well as the endpoint's
      public URL. Defaulting it silently would risk a mismatch between the two.
      """

  config :wedding_planner, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :wedding_planner, WeddingPlannerWeb.Endpoint,
    url: [host: host, port: port, scheme: scheme],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # WebAuthn (passkey) configuration — AUTH-02, AUTH-09. `wax_` is not a dependency
  # yet (task 12 adds it); configuring an application that isn't loaded is harmless,
  # `Application` env is just a term store. This block exists now so the value is
  # derived correctly from day one instead of being retrofitted under time pressure.
  #
  # `origin` MUST equal the scheme, host AND port the browser actually sees, exactly
  # (this was the single most common failure during the passkey spike, there caused
  # by testing on a non-default port). It is built from the very same `scheme`,
  # `host` and `port` used for the endpoint's own `:url` above, so the two cannot
  # drift apart. A default port for the scheme (443 for https, 80 for http) is
  # omitted from the origin string, matching how browsers report `window.location.origin`.
  origin =
    case {scheme, port} do
      {"https", 443} -> "https://#{host}"
      {"http", 80} -> "http://#{host}"
      {scheme, port} -> "#{scheme}://#{host}:#{port}"
    end

  # `rp_id` is the WebAuthn Relying Party ID: normally the bare hostname (no scheme,
  # no port). It becomes effectively permanent the moment a real passkey is enrolled
  # against it — changing it later invalidates every existing passkey. The production
  # hostname has NOT been chosen yet, so this deliberately has no fallback: it MUST be
  # set to the final, real hostname before the very first passkey is ever registered.
  # See DEPLOY.md for the decision this leaves open.
  rp_id =
    System.get_env("WEBAUTHN_RP_ID") ||
      raise """
      environment variable WEBAUTHN_RP_ID is missing.
      For example: wedding.example.com (bare hostname, no scheme, no port)

      This becomes permanent for every passkey enrolled against it. Do not set it
      provisionally — settle the production hostname first. See DEPLOY.md.
      """

  config :wax_,
    origin: origin,
    rp_id: rp_id

  # NFR-05 — HTTPS only. TLS itself is terminated at Fly's edge (see fly.toml's
  # `force_https`), not inside this container, so there is no `:https`/keyfile/certfile
  # endpoint config here. `config/prod.exs`'s `force_ssl` (with `rewrite_on:
  # [:x_forwarded_proto]`) makes Plug trust the proxy's forwarded-proto header and
  # enforce HTTPS from there.
end
