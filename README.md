# Wedding Planner

A small, private web application that helps one couple plan their wedding. It is used by
**exactly two people**, has no guest-facing, vendor-facing or public surface, and is not
intended to become a product.

It exists to answer the cross-cutting questions that spreadsheets and inboxes make hard:
*what does adding these people cost?*, *which venue is actually cheapest for what we
want?*, *what do we need to do now, and what is blocked?*

## The specification lives in `docs/`

**[`docs/README.md`](docs/README.md)** is the entry point — it gives the reading order for
the twelve documents that make up the functional specification, and the conventions they
follow (RFC 2119 keywords, stable rule IDs such as `PER-03` or `CST-31`, normative worked
examples).

`docs/` is maintained deliberately and is not optional background reading. Documentation
changes before code; if the code and `docs/` disagree, that is a bug in one of them.

## Stack

| | |
|---|---|
| Web | Elixir + Phoenix LiveView (no separate SPA) |
| Database | SQLite, via the Ecto SQLite3 adapter |
| Money | `ex_money` / `ex_money_sql`, `Money.Ecto.Map.Type`, EUR |
| Auth | WebAuthn passkeys only — no passwords, no email, no third-party IdP |
| Hosting | Fly.io, **single machine** with a persistent volume |

The reasoning behind each of these, and the alternatives that were rejected, is in
[`docs/06-decisions.md`](docs/06-decisions.md). The binding constraints are in
[`docs/05-non-functional.md`](docs/05-non-functional.md).

Because the database is SQLite on a local volume, **the app must not be scaled beyond one
machine** (NFR-03).

## Running it locally

```sh
mix setup        # fetch deps, create and migrate the database, build assets
mix phx.server   # or: iex -S mix phx.server
```

Then open <http://localhost:4000>.

```sh
mix precommit    # compile --warnings-as-errors, unlock unused deps, format, test
```

Run `mix precommit` before considering any change finished.

## Deployment

Fly.io, one machine, one persistent volume, HTTPS only. The SQLite database is to be
replicated continuously with Litestream, with uploaded files synced alongside it, and
restoring from backup must be documented and tested once. See NFR-03 and NFR-04 in
[`docs/05-non-functional.md`](docs/05-non-functional.md).

> The release tooling (`Dockerfile`, `fly.toml`, `rel/`) has not been written yet.
