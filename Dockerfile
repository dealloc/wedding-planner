# Multi-stage build producing an Elixir release for a single Fly.io machine (NFR-03),
# with Litestream (SQLite -> Tigris replication) and rclone (the uploads directory's
# one-way backup sync) added to the runtime image for NFR-04 / D-32. See litestream.yml,
# rel/overlays/bin/entrypoint, rel/overlays/bin/uploads-sync-loop, and DEPLOY.md.
#
# Debian, not Alpine, to avoid the DNS resolution / NIF-linking issues Alpine is known
# for with BEAM releases. Builder and runner MUST share the same Debian version so the
# release's compiled NIFs (ecto_sqlite3/exqlite) link against matching system libraries.
#
# Pinned, dated tags rather than floating `-slim`/`latest` tags: a release build MUST be
# reproducible and MUST NOT silently pick up a new Elixir/OTP/Debian point release.
ARG ELIXIR_VERSION=1.17.3
ARG OTP_VERSION=27.1.2
ARG DEBIAN_VERSION=bookworm-20251103-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# NFR-04 / D-32 — Litestream (SQLite -> Tigris replication) and rclone (the uploads
# one-way sync, see rel/overlays/bin/uploads-sync-loop) are vendored from their own
# official images rather than downloaded/compiled here: both publish a statically
# linked, CGO-free binary at this exact path, so a plain `COPY --from` is correct
# regardless of the base image's libc (see litestream.io/guides/docker and
# github.com/rclone/rclone's Dockerfile, both built with CGO_ENABLED=0). Pinned,
# specific tags for the same "no silent upgrades" reason as ELIXIR_VERSION etc. above.
ARG LITESTREAM_VERSION=0.5.17
ARG RCLONE_VERSION=1.75.1

FROM litestream/litestream:${LITESTREAM_VERSION} AS litestream
FROM rclone/rclone:${RCLONE_VERSION} AS rclone

FROM ${BUILDER_IMAGE} AS builder

# build-essential: exqlite (SQLite NIF, NFR-02) falls back to compiling from source when
# no precompiled artifact matches the target; git/curl are needed to fetch some deps.
RUN apt-get update -y && apt-get install -y build-essential git curl \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

RUN mix local.hex --force && \
    mix local.rebar --force

ENV MIX_ENV="prod"

# Dependencies first, cached independently of application source changes.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Compile-time config only — config/runtime.exs is intentionally copied later, since it
# reads environment variables that must NOT be baked in at build time.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# priv/ MUST be copied before compiling: it carries the committed locale cache
# (priv/localize/locales/nl-BE.etf, NFR-11) that `:localize` reads at compile/boot time.
# There is deliberately no `mix localize.download_locales` step anywhere in this file —
# the data is committed precisely so this build never needs network access for it.
COPY priv priv
COPY lib lib
COPY assets assets

# mix.exs's `assets.deploy` alias: tailwind + esbuild (minified) + phx.digest.
RUN mix assets.deploy

RUN mix compile

# Now copy the runtime config and release overlays (rel/overlays/bin/migrate and
# rel/overlays/bin/server), and assemble the release.
COPY config/runtime.exs config/
COPY rel rel
RUN mix release

# ---- Runtime image -----------------------------------------------------------------
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# The BEAM release was assembled with a UTF-8 locale available; the runtime image needs
# one too, since e.g. `:localize`/`ex_money` (NFR-10..15) depend on it for formatting.
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

ENV MIX_ENV="prod"

# Deliberately runs as root (no `USER` switch). This is a single-tenant Fly machine
# with no other workloads (NFR-03); the file it would protect against is the SQLite
# database and uploads on the mounted volume, which the app itself must be able to
# create and write to on a brand-new, empty volume (see WeddingPlanner.Release and
# fly.toml's [[mounts]]). Dropping to an unprivileged user would need matching volume
# ownership/permissions set up out of band, which is unnecessary complexity for a
# two-user app with no untrusted code running alongside it.
COPY --from=builder /app/_build/${MIX_ENV}/rel/wedding_planner ./

# NFR-04 / D-32 — the two backup mechanisms. Neither binary needs anything from
# apt beyond the ca-certificates already installed above (both talk HTTPS to Tigris).
COPY --from=litestream /usr/local/bin/litestream /usr/local/bin/litestream
COPY --from=rclone /usr/local/bin/rclone /usr/local/bin/rclone

# Litestream's own config (bucket name/credentials are runtime env vars it expands
# itself — see litestream.yml's comments and DEPLOY.md; nothing sensitive is baked in
# by this COPY, only the *shape* of the replication config).
COPY litestream.yml /etc/litestream.yml

# The entrypoint below (rel/overlays/bin/entrypoint, already present under ./bin from
# the release COPY above) replaces a direct `bin/server` call: it runs Litestream's
# restore-on-boot to completion first, starts the uploads sync loop in the background,
# then hands off to `litestream replicate -exec bin/server`, which supervises the app
# itself. See that script and DEPLOY.md for the full sequencing.
CMD ["/app/bin/entrypoint"]
