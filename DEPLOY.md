# Deployment

This is the release tooling for NFR-03 (Fly.io, single machine, persistent volume) and
NFR-05 (HTTPS only): `Dockerfile`, `fly.toml`, `rel/overlays/`, and the runtime
configuration in `config/runtime.exs`. AUTH-09's operator recovery command (added in a
later task) will run through this same plumbing (`bin/wedding_planner eval "..."`,
wired up the way `bin/migrate` already is).

This document does not cover NFR-04 (Litestream backups for the database, a periodic
sync for uploaded files) — that is separate, not-yet-implemented work. It also does not
cover the AUTH-03 bootstrap setup token, which a later auth task will add its own
environment variable and runtime config for.

## Decision the user still owes: the production hostname

**`fly.toml`'s `app` name and `primary_region` are placeholders, and `PHX_HOST` /
`WEBAUTHN_RP_ID` are deliberately left unset anywhere in this repo.** The hostname
becomes the WebAuthn Relying Party ID (`rp_id`) the moment the first real passkey is
enrolled against it, and `rp_id` is then effectively permanent — changing it later
invalidates every passkey that exists at that point (see `config/runtime.exs`,
AUTH-02/AUTH-09, and `docs/modules/authentication.md`).

**Before the first deploy that will ever see a real passkey enrolled**, decide:

- The production hostname (e.g. `wedding.example.com`, or a Fly-provided
  `<app>.fly.dev` if that's acceptable long-term — note that migrating off a
  `fly.dev` domain later has the same "invalidates every passkey" cost as any other
  hostname change).
- The Fly app name (`fly.toml`'s `app`) and region (`primary_region`) — cheap to change
  before the app and volume are created, essentially fixed afterwards.

Once decided, update `fly.toml`'s `app`/`primary_region`, and set `PHX_HOST` and
`WEBAUTHN_RP_ID` (see below) to the bare hostname (no scheme, no port).

## How the pieces fit together

- **`Dockerfile`** — multi-stage build. Stage 1 (`hexpm/elixir:...-debian-bookworm-...`)
  fetches deps, compiles, runs `mix assets.deploy`, and assembles a release with
  `mix release`. Stage 2 (`debian:bookworm-...`, matching Debian version) copies only
  the assembled release out and runs it. Pinned, dated base image tags — not `-slim` or
  `latest` — so a rebuild months from now doesn't silently pick up a different
  Elixir/OTP/Debian version.

  The locale cache (`priv/localize/locales/nl-BE.etf`, NFR-11) is committed to the repo
  and copied in with the rest of `priv/`; there is deliberately **no**
  `mix localize.download_locales` step, so the build needs network access only for the
  usual `mix deps.get` / hex fetches, nothing else.

- **`rel/overlays/bin/migrate`** and **`rel/overlays/bin/server`** — hand-written
  release commands (equivalents of what `mix phx.gen.release` would generate, written by
  hand instead because running that generator was out of scope for this task). `mix
  release` copies anything under `rel/overlays/` into the release root automatically —
  no `releases:` entry in `mix.exs` is needed for this. `bin/migrate` runs
  `WeddingPlanner.Release.migrate/0` (`lib/wedding_planner/release.ex`); `bin/server`
  sets `PHX_SERVER=true` and starts the app.

- **`lib/wedding_planner/release.ex`** — the module `bin/migrate` calls. Runs Ecto
  migrations (there are none yet — this task adds no schema) and creates the uploads
  directory on the mounted volume if it doesn't exist yet. This is also where AUTH-09's
  recovery command will be added later, invoked the same way.

- **`fly.toml`** — one machine (`min_machines_running = 1`, no scale-to-zero, no
  autoscaling above one, no second `[[vm]]`/process group), one mounted volume at `/data`
  holding both the database and the uploads directory, HTTPS forced
  (`force_https = true`). `release_command` runs `/app/bin/migrate` before each deploy's
  new version takes traffic; `[processes]` runs `/app/bin/server` as the app itself.

  **Nothing in `fly.toml` can *prevent* running `fly scale count 2`** — that's a CLI
  operation, not a config setting. Don't run it: a second machine gets its own empty
  volume, not a copy of this one's SQLite database, which would silently split the data
  (NFR-03).

- **`config/runtime.exs`** — reads `DATABASE_PATH`, `UPLOADS_PATH`, `SECRET_KEY_BASE` and
  `PHX_HOST` from the environment in production, all required (no silent defaults — a
  missing one fails the boot loudly rather than serving from the wrong place or the
  wrong host). It also derives the WebAuthn `origin` (`config :wax_, :origin`) from the
  *same* scheme/host/port used for the endpoint's own `:url`, so the two cannot drift
  apart — this was the most common failure during the passkey spike. `WEBAUTHN_RP_ID` is
  read the same way, with no fallback, for the reason above.

  `wax_` is **not** a dependency yet (a later task adds it); configuring an application
  that isn't loaded is harmless, so this configuration exists now rather than being
  retrofitted later under time pressure.

## Required environment variables (production)

| Variable | Required | Purpose |
|---|---|---|
| `SECRET_KEY_BASE` | Yes | Signs/encrypts cookies and other secrets. Generate with `mix phx.gen.secret`. Set via `fly secrets set`. |
| `DATABASE_PATH` | Yes | Absolute path to the SQLite file, on the mounted volume, e.g. `/data/wedding_planner.db`. |
| `UPLOADS_PATH` | Yes | Absolute path to the uploads directory, on the same mounted volume, e.g. `/data/uploads`. Created automatically by the migrate command if missing. |
| `PHX_HOST` | Yes | The production hostname (bare, no scheme/port), e.g. `wedding.example.com`. See the decision above — no default is provided on purpose. |
| `WEBAUTHN_RP_ID` | Yes | The WebAuthn Relying Party ID. In practice, the same value as `PHX_HOST`. Consumed once `wax_` is added; configured now so it's derived correctly from day one. |
| `PORT` | No (default `4000`, `8080` in `fly.toml`) | Internal HTTP listen port. Must match `fly.toml`'s `[http_service].internal_port`. |
| `POOL_SIZE` | No (default `5`) | SQLite connection pool size. |
| `DNS_CLUSTER_QUERY` | No (unset by default) | Only relevant if clustering is ever introduced; NFR-03's single machine means this is not expected to be used. |
| `PHX_SERVER` | Set by `rel/overlays/bin/server` | Not something an operator needs to set by hand. |

Not yet applicable: the AUTH-03 bootstrap setup token's environment variable (added
alongside the auth module itself), and any Litestream/backup-sync configuration
(NFR-04, separate work).

## First deploy, step by step

These are the manual, one-time Fly operations. None of them are run by this task — they
require an authenticated `fly` account, a chosen app name/region, and the hostname
decision above, none of which exist yet.

```sh
# 1. Settle the hostname decision above, then edit fly.toml's `app` and
#    `primary_region` accordingly.

# 2. Create the app and the single persistent volume (name must match fly.toml's
#    [[mounts]].source; size is a starting point, resizable later).
fly apps create <app-name>
fly volumes create wedding_planner_data --region <region> --size 1

# 3. Set secrets.
fly secrets set \
  SECRET_KEY_BASE="$(mix phx.gen.secret)" \
  PHX_HOST="<production-hostname>" \
  WEBAUTHN_RP_ID="<production-hostname>"

# 4. Deploy. This builds the Dockerfile remotely, runs the release command
#    (/app/bin/migrate) against the fresh volume, then starts /app/bin/server.
fly deploy
```

## Restore-from-backup drill (NFR-04)

Not yet applicable — Litestream and the uploads sync are not implemented. NFR-04
requires restoring both the database and uploaded files to be documented and tested
once; that belongs with the task that adds the backup mechanism itself.
