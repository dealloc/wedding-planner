# Deployment

This is the release tooling for NFR-03 (Fly.io, single machine, persistent volume) and
NFR-05 (HTTPS only): `Dockerfile`, `fly.toml`, `rel/overlays/`, `litestream.yml`, and the
runtime configuration in `config/runtime.exs`. AUTH-09's operator recovery command (added
in a later task) will run through this same plumbing (`bin/wedding_planner eval "..."`,
wired up the way `bin/migrate` already is).

It also covers NFR-04 (continuous backups) and D-32: Litestream, replicating the SQLite
database to Fly's S3-compatible storage (Tigris), and a separate periodic one-way sync of
the uploads directory to the same bucket. **These are two different mechanisms covering
two different things — see "The backup asymmetry" below before changing either one.**

This document does not cover the AUTH-03 bootstrap setup token, which a later auth task
will add its own environment variable and runtime config for.

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

- **`litestream.yml`** — Litestream's own config, copied to `/etc/litestream.yml` in the
  runtime image. Declares one database (`$DATABASE_PATH`) replicated to one S3-compatible
  replica (Tigris). Every bucket/credential field is a `${VAR}` Litestream expands from
  the environment at startup (its own built-in substitution, nothing Elixir-related) —
  none of it is baked into the file or the image. See "The backup asymmetry" below.

- **`rel/overlays/bin/entrypoint`** — the Dockerfile's `CMD`, replacing a direct
  `bin/server` call. In order: (1) fail loudly if any `BACKUP_*` env var is unset: NFR-04
  is not optional, so a missing credential is an unmissable boot failure, not a silently
  skipped backup; (2) `litestream restore -if-db-not-exists -if-replica-exists` — this is
  what makes the database restore complete *before* the app ever starts, satisfying the
  "app must not start before restore completes" requirement, and it's a documented no-op
  both when the volume already has a database and on the very first boot before anything
  has ever been replicated; (3) start `bin/uploads-sync-loop` in the background; (4)
  `exec litestream replicate -exec "/app/bin/server"`, so Litestream becomes the
  container's main process and supervises the app as its child — if the app exits,
  Litestream exits too, and Fly restarts the machine.

- **`rel/overlays/bin/uploads-sync-loop`** — the *other* NFR-04 mechanism, and unrelated
  to Litestream. Every `UPLOADS_SYNC_INTERVAL_SECONDS` (default 900s / 15 minutes), runs
  `rclone sync $UPLOADS_PATH backup:$BACKUP_BUCKET/uploads` — one-way, local to bucket,
  configured entirely from `RCLONE_CONFIG_BACKUP_*` environment variables it sets from
  the same `BACKUP_*` vars Litestream uses (one shared bucket, two prefixes: `db/` and
  `uploads/`), so there is no rclone config file anywhere either. A failed sync is logged
  and retried on the next tick; it never touches, restores from, or blocks the local
  copy in `$UPLOADS_PATH`.

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

## The backup asymmetry (NFR-04, XC-23, D-32) — read this before touching either mechanism

NFR-04 needs two *unrelated* mechanisms because one does not cover both kinds of data.
Getting this backwards is invisible until the day it matters (restore day), so it is
spelled out here rather than left to be re-derived from the code:

| | **Litestream** (`litestream.yml`, `bin/entrypoint`) | **uploads sync** (`bin/uploads-sync-loop`) |
|---|---|---|
| Covers | The SQLite database only | The uploads directory only |
| Direction | Continuous, near-real-time WAL shipping | Periodic, one-way, local → bucket |
| Restore on boot | Yes, automatic (`litestream restore`, every boot) | **No.** Never automatic, in either direction |
| App reads from bucket at request time? | No — the app only ever talks to the local SQLite file | No — files are always served from `$UPLOADS_PATH` (XC-23) |
| Bucket's role | Backup target, written to by Litestream | Backup target, written to by `rclone`; **never read from except in a manual disaster-recovery restore** |

The bucket (Tigris) is **write-only from the app's perspective** in both cases. No object
store sits in the request path (XC-23) — this is not a contradiction of "the bucket is a
backup target" (D-32), it's the whole point: the same bucket receives two independent,
one-way streams of data (`db/` from Litestream, `uploads/` from `rclone`), and nothing in
the running app ever issues a request *to* that bucket. If you ever find yourself adding
code that reads a file from the bucket to serve a request, that is a violation of XC-23
and D-32, not a feature.

**NFR-03 also matters here**: Litestream assumes exactly one writer to the SQLite file at
a time. That is already a hard requirement for SQLite itself on Fly (NFR-03 — this app
MUST NOT be scaled past one machine), but it's worth restating: running a second machine
against the same replica would not just silently split the data (as NFR-03's fly.toml
comments already say) — it would also make Litestream's replication itself unreliable,
since it is not designed to arbitrate between two concurrent writers.

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
| `BACKUP_BUCKET` | Yes | Tigris bucket name both backup mechanisms write to. Not sensitive by itself, but set via `fly secrets set` alongside the credentials below for simplicity — see "Restore-from-backup drill". |
| `BACKUP_ENDPOINT` | Yes | Tigris's S3-compatible endpoint, e.g. `https://fly.storage.tigris.dev`. Not defaulted, deliberately — same "no silent default for anything hostname-shaped" reasoning as `PHX_HOST`. |
| `BACKUP_REGION` | Yes | S3 region string. Tigris ignores the value but the S3 protocol requires a non-empty one; `auto` is Tigris's own recommended value. |
| `BACKUP_ACCESS_KEY_ID` | Yes | Tigris access key, scoped to `BACKUP_BUCKET`. Secret — `fly secrets set` only, never in `fly.toml`. |
| `BACKUP_SECRET_ACCESS_KEY` | Yes | Tigris secret key. Secret — `fly secrets set` only, never in `fly.toml`. |
| `UPLOADS_SYNC_INTERVAL_SECONDS` | No (default `900`) | How often `bin/uploads-sync-loop` runs. See that script's comments for why 15 minutes was chosen. |

All five `BACKUP_*` variables are consumed by `rel/overlays/bin/entrypoint`,
`litestream.yml` and `rel/overlays/bin/uploads-sync-loop` (NFR-04, D-32) — not by
`config/runtime.exs`; the app itself never reads them, because the app never talks to
the bucket (see "The backup asymmetry" above).

Not yet applicable: the AUTH-03 bootstrap setup token's environment variable, added
alongside the auth module itself.

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

# 3. Create the Tigris bucket (NFR-04, D-32) and capture the credentials it prints —
#    `fly storage create` provisions a bucket and its own access key/secret, and can
#    print them as AWS_*-named values; map them onto the BACKUP_* names below (the
#    values matter, the env var names are this app's own, chosen so one set of
#    credentials is shared by Litestream and the uploads sync, see litestream.yml and
#    bin/uploads-sync-loop).
fly storage create

# 4. Set secrets.
fly secrets set \
  SECRET_KEY_BASE="$(mix phx.gen.secret)" \
  PHX_HOST="<production-hostname>" \
  WEBAUTHN_RP_ID="<production-hostname>" \
  BACKUP_BUCKET="<bucket-name-from-step-3>" \
  BACKUP_ENDPOINT="https://fly.storage.tigris.dev" \
  BACKUP_REGION="auto" \
  BACKUP_ACCESS_KEY_ID="<access-key-from-step-3>" \
  BACKUP_SECRET_ACCESS_KEY="<secret-key-from-step-3>"

# 5. Deploy. This builds the Dockerfile remotely, runs the release command
#    (/app/bin/migrate) against the fresh volume, then starts /app/bin/entrypoint,
#    which restores the database (a no-op on a brand-new bucket — see "The backup
#    asymmetry" above), starts the uploads sync loop, and hands off to
#    `litestream replicate -exec /app/bin/server`.
fly deploy
```

## Restore-from-backup drill (NFR-04)

NFR-04 requires restoring **both** the database and the uploaded files to be documented
and tested once. They are two different drills, on purpose (see "The backup asymmetry"
above) — do not assume restoring one restores the other.

### Database — automatic, verify by observing it

Litestream's restore runs on every boot (`bin/entrypoint`, before the app starts), so the
drill is: delete the database and confirm a restart brings it back.

```sh
# Confirm Litestream is actually shipping WAL segments before relying on this drill —
# tail the logs and look for its own periodic replication output.
fly logs

# Simulate losing the local database (e.g. after a lost/corrupted volume) by removing it
# on the running machine, then let the container restart so bin/entrypoint's restore
# step runs against a "fresh volume" state.
fly ssh console -C "rm /data/wedding_planner.db"
fly machine restart <machine-id>

# Confirm the data is back: check the app itself for data you know existed before the
# restart (once there's a schema to query, `fly ssh console -C "/app/bin/wedding_planner
# rpc '...'"` against it works the same way `bin/migrate` does), and check `fly logs`
# for the entrypoint's own log line ("entrypoint: restoring ...") to see it actually ran
# the restore rather than skipping via -if-db-not-exists.
```

Litestream also exposes its own inspection commands against the same config/bucket
(`litestream databases -config /etc/litestream.yml`, `litestream snapshots ...`,
`litestream wal ...` — run via `fly ssh console`) if deeper verification of what has
actually reached the bucket is ever needed beyond the log output.

### Uploaded files — manual only, never automatic

There is deliberately no "restore uploads on boot" step — see "The backup asymmetry".
Restoring the uploads directory is a manual, human-invoked disaster-recovery action:

```sh
# From an operator machine (or fly ssh console) with the same BACKUP_* credentials —
# note the direction is reversed from bin/uploads-sync-loop's normal bucket <- local
# sync: this is the one and only place data is ever meant to flow bucket -> local.
RCLONE_CONFIG_BACKUP_TYPE=s3 \
RCLONE_CONFIG_BACKUP_PROVIDER=Other \
RCLONE_CONFIG_BACKUP_ACCESS_KEY_ID="$BACKUP_ACCESS_KEY_ID" \
RCLONE_CONFIG_BACKUP_SECRET_ACCESS_KEY="$BACKUP_SECRET_ACCESS_KEY" \
RCLONE_CONFIG_BACKUP_ENDPOINT="$BACKUP_ENDPOINT" \
RCLONE_CONFIG_BACKUP_REGION="$BACKUP_REGION" \
  rclone sync "backup:${BACKUP_BUCKET}/uploads" /data/uploads
```

Verify by uploading a file through the app, waiting for `UPLOADS_SYNC_INTERVAL_SECONDS`
(default 15 minutes), and confirming it exists under `uploads/` in the bucket (Tigris's
web console, or `rclone ls backup:$BACKUP_BUCKET/uploads`) — then, separately, confirm
that *viewing* that file in the app never causes a request to the bucket (XC-23): the
app serves it from `$UPLOADS_PATH` on the local volume, full stop.
