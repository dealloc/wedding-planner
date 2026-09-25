defmodule WeddingPlanner.Accounts.Recovery do
  @moduledoc """
  AUTH-09: the operator recovery command. Generates a recovery-flavour enrollment link
  for an existing user who has lost every device holding a passkey — the escape hatch
  AUTH-09 requires, since there is no password to reset.

  Run from a built release:

      bin/wedding_planner eval 'WeddingPlanner.Accounts.Recovery.recover("Wannes")'

  (a numeric user id works too). It lives here rather than in a `WeddingPlanner.Release`
  module so the release tooling Fly generates (`mix phx.gen.release`, which writes
  `lib/wedding_planner/release.ex` with `migrate/0` and `rollback/2`) never collides
  with it.

  Elixir's release `eval` boots a **non-started** system instance — code is loaded, but
  no application's supervision tree runs. `recover/1` therefore opens the repo itself via
  `Ecto.Migrator.with_repo/2` and starts a bare `Phoenix.PubSub` server under its own
  supervisor so `WeddingPlanner.Log`'s existing broadcast-on-write keeps working
  unmodified (see `start_pubsub!/0`). It never starts `WeddingPlannerWeb.Endpoint` (no
  HTTP listener) and is not given a connected user — it prints a URL and exits.

  `generate_recovery_link/1` is the testable core: it assumes a repo connection already
  exists, true both under `mix test` and inside `recover/1`'s `with_repo` wrapper, so
  `mix test` can exercise the real lookup/creation/logging logic without booting a
  release or calling `System.halt/1`.
  """

  @app :wedding_planner

  alias WeddingPlanner.Accounts.EnrollmentLinks
  alias WeddingPlanner.Accounts.Scope
  alias WeddingPlanner.Accounts.User
  alias WeddingPlanner.Log
  alias WeddingPlanner.Repo

  @doc """
  AUTH-09: the operator recovery command's entry point, run from a built release (see
  the moduledoc). `identifier` is looked up as a numeric user id if it parses as one,
  otherwise as an exact `display_name` match.

  On success, prints **only** the enrollment URL to stdout — the one channel this
  command has to convey it to the operator, who relays it out of band. Never calls
  `Logger`: the token embedded in that URL must never reach the application log.

  On an unknown identifier, prints a clear message to stderr and exits non-zero
  (`System.halt/1`) — this is invoked by a human at a terminal, not read
  programmatically, so a sharp failure matters more than a return value.
  """
  @spec recover(String.t()) :: no_return() | :ok
  def recover(identifier) when is_binary(identifier) do
    load_app()
    start_pubsub!()

    {:ok, result, _apps} =
      Ecto.Migrator.with_repo(Repo, fn _repo -> generate_recovery_link(identifier) end)

    case result do
      {:ok, url} ->
        IO.puts(url)

      {:error, :not_found} ->
        IO.puts(
          :stderr,
          "No user found matching #{inspect(identifier)}. " <>
            "Pass a numeric user id or an exact display name."
        )

        System.halt(1)
    end
  end

  @doc """
  The testable core of `recover/1` (see moduledoc): looks `identifier` up, generates a
  recovery link with no issuing user (`EnrollmentLinks.create_recovery_link/1`), logs
  its creation, and returns the enrollment URL. Assumes a repo connection is already
  available — safe to call directly under `mix test`.

  ## Log attribution (AUTH-11)

  `WeddingPlanner.Log.entry/3` requires a `Scope` wrapping a real `User` — there is no
  anonymous/"system" scope in its API, and `activity_entries.user_id` is a mandatory,
  `on_delete: :restrict` foreign key (`docs/03-domain-model.md`'s `USER ||--o{
  ACTIVITY_ENTRY`), so an entry genuinely cannot exist with no user at all. There is
  also no operator/system `User` row in this domain — exactly two users ever exist
  (`docs/03-domain-model.md`), and inventing a third would be its own kind of drift.

  Given that, the only real `User` this command has anything to do with is the link's
  **target** user, so the entry is attributed to them via `Scope.for_user(target_user)`
  — but the *description* says plainly that an operator did this, not the user
  themselves, which is the distinction AUTH-11 actually cares about: the log must not
  read as if the target user requested their own recovery link.
  """
  @spec generate_recovery_link(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def generate_recovery_link(identifier) when is_binary(identifier) do
    case find_user(identifier) do
      nil ->
        {:error, :not_found}

      %User{} = user ->
        {:ok, link} = EnrollmentLinks.create_recovery_link(user)

        Log.entry(
          Scope.for_user(user),
          {:enrollment_link, link.id},
          "An operator generated a recovery enrollment link for #{user.display_name}"
        )

        {:ok, enrollment_url(link.token)}
    end
  end

  defp find_user(identifier) do
    case Integer.parse(identifier) do
      {id, ""} -> Repo.get(User, id)
      _ -> Repo.get_by(User, display_name: identifier)
    end
  end

  # Builds the enrollment URL from the endpoint's own `:url`/`:http`/`:https` config,
  # the same values `config/runtime.exs` sets from `PHX_HOST` in prod (mirroring
  # `Phoenix.Endpoint.Supervisor`'s own `build_url/2`) — deliberately *not*
  # `WeddingPlannerWeb.Endpoint.url/0` or the `~p` sigil, both of which read from a
  # `:persistent_term` only populated once the endpoint process has started, which it
  # never does under `eval` (see moduledoc). This keeps the command genuinely
  # independent of Phoenix's runtime, not just of a connected request.
  defp enrollment_url(token) do
    endpoint_base_url() <> "/enroll/" <> token
  end

  defp endpoint_base_url do
    config = Application.get_env(@app, WeddingPlannerWeb.Endpoint, [])
    url_config = Keyword.get(config, :url, [])
    https = Keyword.get(config, :https)
    http = Keyword.get(config, :http)

    {default_scheme, default_port} =
      cond do
        https -> {"https", Keyword.get(https, :port, 443)}
        http -> {"http", Keyword.get(http, :port, 80)}
        true -> {"http", 80}
      end

    scheme = Keyword.get(url_config, :scheme, default_scheme)
    host = Keyword.get(url_config, :host, "localhost")
    port = Keyword.get(url_config, :port, default_port)

    URI.to_string(%URI{scheme: scheme, host: host, port: port})
  end

  # `eval` loads `:wedding_planner` but starts nothing (see moduledoc), so the
  # `WeddingPlanner.PubSub` name `WeddingPlanner.Log`'s write-through broadcast relies
  # on (via `WeddingPlanner.Realtime`) does not exist yet. Rather than touch `log.ex` or
  # `realtime.ex` to make broadcasting optional, this starts the same named PubSub
  # server the full application would, under a throwaway supervisor — no Endpoint, no
  # HTTP listener, nothing web-specific, just the one dependency `Log.entry/3` actually
  # needs to complete.
  defp start_pubsub! do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    {:ok, _pid} =
      Supervisor.start_link([{Phoenix.PubSub, name: WeddingPlanner.PubSub}],
        strategy: :one_for_one
      )

    :ok
  end

  defp load_app do
    Application.load(@app)
  end
end
